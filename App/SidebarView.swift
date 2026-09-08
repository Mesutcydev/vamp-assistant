import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var sessions: AgentSessionController
    @Binding var showRemoteAccess: Bool
    let onClose: () -> Void
    // Sessions are decrypted OFF the main thread: loadAll() does Keychain +
    // AES-GCM per file, which blocked body evaluation (and hung the app when
    // the ad-hoc build raised a Keychain prompt). The list renders from
    // async-loaded state instead.
    @State private var recentSessions: [SessionRecord] = []
    /// Sidebar list selection IS the session switch: rows are tagged with
    /// their record id and onChange restores the picked session. Native
    /// selection gives the rows a real selected state (plain Buttons inside
    /// a sidebar List had no visible selection and failed silently).
    @State private var selectedSessionID: UUID?
    /// Shown when a picked session can't be restored (e.g. its project
    /// folder no longer exists) instead of the old silent no-op.
    @State private var sessionRestoreError: String?
    /// Which history the list shows: BeetCode's own sessions or chats
    /// imported from Claude / Codex / Cursor.
    @State private var sidebarTab: SidebarHistoryTab = .sessions
    @State private var isImporting = false
    @State private var isImportingBundle = false
    @State private var importSummary: String?
    @State private var importSummaryIsWarning = false
    /// Live parser feedback while an import runs (source + file + count).
    @State private var importStatus: String?
    @State private var hasAutoImported = false
    @State private var historySearch = ""
    @State private var pinnedSessionIDs: Set<UUID> = []

    private enum TaskStatus: Equatable {
        case running(String)
        case review
        case completed
        case stopped
        case idle
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeaderView(
                workspaceURL: sessions.workspaceURL,
                sidebarTab: sidebarTab,
                historySearch: $historySearch,
                queuedTasks: pendingQueueTasks,
                isImporting: isImporting,
                isImportingBundle: isImportingBundle,
                onChooseWorkspace: chooseWorkspace,
                onChatOnly: startChatOnly,
                onImport: runImport,
                onImportTaskBundle: runTaskBundleImport,
                onRefresh: { Task { await reloadSessions() } },
                onSelectTab: { sidebarTab = $0 },
                onRunNext: { appState.drainTaskQueue() },
                onRemoveQueuedTask: { appState.removeQueuedTask($0) },
                onClose: onClose
            )
            List {
                if sidebarTab == .sessions {
                    ownSections
                } else {
                    importedSections
                }
            }
            // NavigationSplitView already owns the sidebar silhouette. A
            // nested `.sidebar` list adds its own inset border and rounded
            // bottom corners on current macOS, which leaves a doubled frame
            // that cannot follow the window corners. Plain keeps the list's
            // scrolling behavior without introducing a second container
            // shape; rows own their selection so AppKit cannot override it.
            .listStyle(.plain)
            // Let the window atmosphere show through the single native
            // NavigationSplitView sidebar surface.
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            // Keep the last history row above the fixed navigation tools. A
            // sibling footer lets AppKit's scroll view draw underneath it,
            // which clipped the final message count in the drawer.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarFooter
            }
        }
        .sidebarSurface()
        .accessibilityIdentifier("conversation-browser")
        // Selection IS the restore: picking a tagged row switches to that
        // session (and reports why when it can't — no more silent no-ops).
        .onChange(of: selectedSessionID) { _, newValue in
            selectSession(newValue)
        }
        // First visit to the Imported tab runs one automatic import; later
        // visits are free until the user presses re-import.
        .onChange(of: sidebarTab) { _, newTab in
            if newTab == .imported && !hasAutoImported {
                hasAutoImported = true
                if !recentSessions.contains(where: { $0.source != .app }) {
                    runImport()
                }
            }
        }
        // Off-main load + reload whenever a session is saved (controller
        // publishes transcript/session changes through objectWillChange).
        .task { await reloadSessions() }
        .onReceive(NotificationCenter.default.publisher(for: .remoteSessionsChanged)) { note in
            // A paired device deleted or renamed a chat; nothing else
            // invalidates this view's decrypted snapshot.
            if let id = note.object as? UUID {
                pinnedSessionIDs.remove(id)
                if selectedSessionID == id { selectedSessionID = nil }
            }
            Task { await reloadSessions() }
        }
        .onChange(of: sessions.isRunning) { _, running in
            guard !running else { return }
            Task { await reloadSessions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionTitleChanged)) { _ in
            Task { await reloadSessions() }
        }
    }

    private var pendingQueueTasks: [QueuedAgentTask] {
        appState.queuedTasks.filter { !$0.state.isTerminal }
    }

    // MARK: Sidebar footer

    /// The sidebar footer is intentionally limited to destinations that
    /// belong to navigation. Browser, Simulator and Diagnostics live in the
    /// window toolbar.
    /// Bottom drawer status: a connection dot + label on the left (like the
    /// reference client's "Codex · connected"). Settings is owned by the
    /// permanent spine, so the drawer does not duplicate its button.
    private var sidebarFooter: some View {
        HStack(spacing: Spacing.sm) {
            connectionMenu
            Spacer(minLength: 4)
        }
        .padding(.horizontal, SidebarMetrics.inset)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        // The footer is the drawer's own base — it continues the sidebar
        // surface exactly, never a contrasting strip.
        .background(
            LinearGradient(colors: [Theme.navigationSurface, Instrument.silverLow.opacity(0.94)],
                           startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) { SidebarDivider() }
        .zIndex(1)
    }

    /// One connection indicator with a readable label; secondary services
    /// (remote sessions, models) live in the disclosure popover, preserving
    /// their real actions without crowding the strip.
    private var connectionMenu: some View {
        InstrumentMenu(menuWidth: 240) {
            HStack(spacing: 6) {
                VampStatusDot(color: connectionColor)
                Text(connectionLabel)
                    .font(.appUI(size: 12, weight: .medium))
                    .foregroundStyle(Instrument.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Instrument.inkSecondary)
            }
            .frame(height: 30)
            .contentShape(Rectangle())
        } options: {
            InstrumentMenuRow(title: "Connection: \(connectionLabel)",
                              systemImage: "circle.fill",
                              isSelected: false,
                              help: "Current engine state") {}
            InstrumentMenuRow(
                title: appState.remoteSessionRunning
                    ? "Remote sessions — running" : "Remote sessions…",
                systemImage: "antenna.radiowaves.left.and.right") {
                showRemoteAccess = true
            }
            InstrumentMenuRow(title: "Models…", systemImage: "cpu") {
                NotificationCenter.default.post(name: .openModelManager, object: nil)
            }
        }
        .fixedSize()
        .help("Connection and services")
        .accessibilityLabel("Connection: \(connectionLabel). Menu shows remote sessions and models.")
    }

    /// Engine connection state for the footer status line.
    private var connectionColor: Color {
        switch appState.enginePhase {
        case .ready: Theme.positive
        case .loading: Theme.warning
        case .failed: Theme.danger
        case .idle: Theme.statusNeutral
        }
    }

    private var connectionLabel: String {
        switch appState.enginePhase {
        case .ready(let name): return "\(name) · connected"
        case .loading(let name): return "Loading \(name)…"
        case .failed: return "Model failed"
        case .idle:
            return appState.remoteSessionRunning ? "Remote · connected" : "No model"
        }
    }


    private func footerTool(_ title: String, icon: String, isActive: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: icon)
                    .font(.app(size: 12, weight: .semibold ))
                Text(title)
                    .font(.app(size: 12, weight: .medium ))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? Theme.rose : Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: SidebarMetrics.rowHeight)
            .background(isActive ? Theme.wash(Theme.accent) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(LFPlainPressButtonStyle())
        .lfHoverLift()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: Own sessions

    @ViewBuilder
    private var ownSections: some View {
        if needsKeychainUnlock || sessionRestoreError != nil {
            Section {
            if needsKeychainUnlock {
                HStack(spacing: Spacing.sm) {
                    Text("History is locked")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                    Spacer()
                    Button("Unlock") {
                        if SessionCrypto.unlockInteractively() {
                            needsKeychainUnlock = false
                            Task { await reloadSessions() }
                        }
                    }
                    .controlSize(.small)
                }
            }
            if let restoreError = sessionRestoreError {
                Label(restoreError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .lineLimit(3)
            }
            }
        }

        if sessions.workspaceURL != nil {
            Section {
                if let output = sessions.gitOutput {
                    ScrollView {
                        Text(output)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                    .padding(6)
                    .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                }
            } header: {
                SidebarGroupHeader(
                    icon: "folder.fill",
                    appIcon: sessions.workspaceURL.flatMap { AppIconLookup.workspace($0.path) },
                    name: sessions.workspaceURL?.lastPathComponent ?? "Project",
                    count: nil)
            }
        }

        let own = visibleOwnSessions
        if own.isEmpty, !needsKeychainUnlock {
            Section {
                ownHistoryEmptyState
            }
        } else if historySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Reference-client history: flat date sections (TODAY /
            // YESTERDAY / EARLIER), newest first — not project folders.
            ForEach(dateSections(own), id: \.title) { section in
                Section {
                    ForEach(sortedTasks(section.records)) { record in
                        sessionRow(record, subtitle: workspaceSubtitle(for: record))
                    }
                } header: {
                    HStack(spacing: 7) {
                        Text(section.title.uppercased())
                            .font(.appUI(size: 10, weight: .semibold))
                            .tracking(1.25)
                            .foregroundStyle(Instrument.engraved)
                        Rectangle()
                            .fill(Instrument.seam.opacity(0.42))
                            .frame(height: 0.75)
                    }
                    .padding(.leading, 2)
                    .padding(.top, 10)
                    .padding(.bottom, 3)
                }
            }
        } else {
            ForEach(projectGroups(own)) { group in
                collapsibleGroup(key: "own:" + group.key, icon: group.icon,
                                 name: group.name, records: group.records,
                                 workspacePath: group.key, subtitle: nil)
            }
        }

    }

    /// Short workspace name used as the history row subtitle, so each chat
    /// reads like the reference client ("vamp-assistant · 14 messages").
    private func workspaceSubtitle(for record: SessionRecord) -> String? {
        guard !record.workspacePath.isEmpty else { return nil }
        return URL(fileURLWithPath: record.workspacePath).lastPathComponent
    }

    /// Splits history into TODAY / YESTERDAY / EARLIER by last activity.
    private func dateSections(_ records: [SessionRecord]) -> [(title: String, records: [SessionRecord])] {
        let calendar = Calendar.current
        var today: [SessionRecord] = []
        var yesterday: [SessionRecord] = []
        var earlier: [SessionRecord] = []
        for record in records {
            if calendar.isDateInToday(record.updatedAt) {
                today.append(record)
            } else if calendar.isDateInYesterday(record.updatedAt) {
                yesterday.append(record)
            } else {
                earlier.append(record)
            }
        }
        var sections: [(title: String, records: [SessionRecord])] = []
        if !today.isEmpty { sections.append((title: "Today", records: today)) }
        if !yesterday.isEmpty { sections.append((title: "Yesterday", records: yesterday)) }
        if !earlier.isEmpty { sections.append((title: "Earlier", records: earlier)) }
        return sections
    }

    private var ownHistoryEmptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.app(size: 18, weight: .medium ))
                .foregroundStyle(Theme.accentText)
            Text("Your work will stay close")
                .font(.app(size: 12, weight: .semibold ))
                .foregroundStyle(Theme.textPrimary)
            Text("Chats are saved locally and grouped by project as soon as you start a task.")
                .font(.app(size: 11 ))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .listRowInsets(EdgeInsets(top: Spacing.sm, leading: SidebarMetrics.inset, bottom: Spacing.sm, trailing: SidebarMetrics.inset))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var visibleOwnSessions: [SessionRecord] {
        let own = recentSessions.filter { $0.source == .app }
        return own.filter { matchesSearch($0) }
    }

    private func matchesSearch(_ record: SessionRecord) -> Bool {
        let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        if SessionTitle.display(for: record).lowercased().contains(query) { return true }
        if record.workspacePath.lowercased().contains(query) { return true }
        return record.messages.contains {
            $0.role == .user && $0.content.lowercased().contains(query)
        }
    }

    private func taskStatus(for record: SessionRecord) -> TaskStatus {
        if record.id == sessions.activeSessionID {
            if sessions.isRunning {
                return .running(phaseLabel(sessions.currentPhase))
            }
            if let finishReason = sessions.finishReason {
                switch finishReason {
                case .completed:
                    return .completed
                case .cancelled:
                    return .stopped
                case .declined, .maxTurnsReached, .engineError:
                    return .review
                }
            }
        }

        if let verification = record.messages.reversed().first(where: {
            $0.toolName == "build_diagnostics"
        }), verificationFailed(verification.content) {
            return .review
        }
        if let lastTool = record.messages.reversed().first(where: {
            $0.role == .toolResult
        }), lastTool.content.hasPrefix("error:") {
            return .review
        }
        return record.messages.contains(where: { $0.role == .assistant }) ? .completed : .idle
    }

    private func verificationFailed(_ output: String) -> Bool {
        output.hasPrefix("error:") || output.contains("exit status ")
    }

    private func phaseLabel(_ phase: AgentPhase) -> String {
        switch phase {
        case .planning, .awaitingPlanApproval: "Planning"
        case .working: "Running"
        case .awaitingApproval: "Needs approval"
        case .awaitingQuestion: "Waiting for you"
        case .verifying: "Verifying"
        case .idle, .finished: "Running"
        }
    }

    private func taskStatusTitle(_ status: TaskStatus) -> String? {
        switch status {
        case .running(let label): label
        case .review: "Review"
        case .stopped: "Stopped"
        case .completed, .idle: nil
        }
    }

    private func taskStatusIcon(_ status: TaskStatus) -> String {
        switch status {
        case .running: "circle.fill"
        case .review: "exclamationmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .idle: "circle"
        }
    }

    private func taskStatusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .running: Theme.accent
        case .review: Theme.warning
        case .stopped: Theme.textTertiary
        case .completed: Theme.success
        case .idle: Theme.textTertiary
        }
    }

    private func workspacePathLabel(_ path: String) -> String {
        guard !path.isEmpty else { return "Chat only" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "Home" }
        return path
    }

    private func togglePinned(_ record: SessionRecord) {
        var updated = pinnedSessionIDs
        if updated.contains(record.id) {
            updated.remove(record.id)
        } else {
            updated.insert(record.id)
        }
        var preferences = AppPreferencesStore.shared.current
        preferences.pinnedSessionIDs = updated.sorted { $0.uuidString < $1.uuidString }
        AppPreferencesStore.shared.save(preferences)
        pinnedSessionIDs = updated
    }

    private func sortedTasks(_ records: [SessionRecord]) -> [SessionRecord] {
        records.sorted {
            let lhsPinned = pinnedSessionIDs.contains($0.id)
            let rhsPinned = pinnedSessionIDs.contains($1.id)
            if lhsPinned != rhsPinned { return lhsPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    // MARK: Imported history

    @ViewBuilder
    private var importedSections: some View {
        if isImporting, let importStatus {
            Section {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text(importStatus)
                        .font(.app(size: 11, weight: .medium ))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.wash(Theme.info), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Theme.washBorder(Theme.info), lineWidth: 1))
                .listRowInsets(EdgeInsets(top: Spacing.xs, leading: SidebarMetrics.inset, bottom: Spacing.xs, trailing: SidebarMetrics.inset))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        } else if let importSummary {
            let foundNothing = importSummary.hasPrefix("No ")
            let warningSummary = importSummaryIsWarning || foundNothing
            let summaryTint = warningSummary ? Theme.warning : Theme.success
            Section {
                Label(importSummary, systemImage: warningSummary ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(summaryTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.wash(summaryTint), in: Capsule())
                    .listRowInsets(EdgeInsets(top: Spacing.xs, leading: SidebarMetrics.inset, bottom: Spacing.xs, trailing: SidebarMetrics.inset))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }

        let imported = recentSessions.filter { $0.source != .app }
        if imported.isEmpty {
            Section {
                importedEmptyState
            }
        } else {
            Section {
                importSourceBar(imported)
            }

            let filtered = visibleImported(imported)
            if filtered.isEmpty {
                Section {
                    emptySearchState(historySearch.isEmpty
                                     ? "No chats from \(sourceFilter?.label ?? "this tool")."
                                     : "No chats match “\(historySearch)”.")
                }
            } else {
                ForEach(projectGroups(filtered)) { group in
                    collapsibleGroup(key: "import-project:" + group.key,
                                     icon: group.icon,
                                     name: group.name,
                                     records: group.records,
                                     workspacePath: group.key,
                                     subtitle: { $0.source.label })
                }
            }
        }
    }

    private var importedEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .accessibilityHidden(true)
                .font(.app(size: 18, weight: .medium ))
                .foregroundStyle(Theme.accentText)
            Text("Continue work from other tools")
                .font(.app(size: 12, weight: .semibold ))
                .foregroundStyle(Theme.textPrimary)
            Text("Find Claude, Codex, and Cursor chats, then organize them by project. Everything stays on this Mac.")
                .font(.app(size: 11 ))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                runImport()
            } label: {
                Label("Scan for chats", systemImage: "arrow.clockwise")
                    .font(.app(size: 11, weight: .semibold ))
            }
            .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
            .disabled(isImporting)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .listRowInsets(EdgeInsets(top: Spacing.sm, leading: SidebarMetrics.inset, bottom: Spacing.sm, trailing: SidebarMetrics.inset))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func emptySearchState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textTertiary)
            Text(message)
                .font(.app(size: 11, weight: .medium ))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 8)
    }

    private func importSourceBar(_ imported: [SessionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Filter by source")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(imported.count) chats")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    sourcePill(source: nil, label: "All", icon: "tray.full", count: imported.count)
                    ForEach(importSources, id: \.self) { source in
                        sourcePill(source: source, label: source.label,
                                   icon: source.systemImage,
                                   count: imported.filter { $0.source == source }.count)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .listRowInsets(EdgeInsets(top: Spacing.xs, leading: SidebarMetrics.inset, bottom: Spacing.xs, trailing: SidebarMetrics.inset))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func visibleImported(_ imported: [SessionRecord]) -> [SessionRecord] {
        let sourced = sourceFilter == nil ? imported : imported.filter { $0.source == sourceFilter }
        let query = historySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sourced }
        return sourced.filter { record in
            if SessionTitle.display(for: record).lowercased().contains(query) { return true }
            if record.workspacePath.lowercased().contains(query) { return true }
            return record.messages.contains {
                $0.role == .user && $0.content.lowercased().contains(query)
            }
        }
    }

    /// Whole-header expand/collapse. Native `Section(isExpanded:)` only
    /// toggles from the trailing chevron; a click on the plate must work too.
    @ViewBuilder
    private func collapsibleGroup(
        key: String,
        icon: String,
        name: String,
        records: [SessionRecord],
        workspacePath: String? = nil,
        subtitle: ((SessionRecord) -> String)? = nil
    ) -> some View {
        let expanded = !collapsedProjects.contains(key)
        let path = workspacePath ?? key
        let appIcon = AppIconLookup.header(path: path, records: records)
        Section {
            if expanded {
                ForEach(records) { record in
                    sessionRow(record, subtitle: subtitle?(record))
                }
            }
        } header: {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expanded {
                        collapsedProjects.insert(key)
                    } else {
                        collapsedProjects.remove(key)
                    }
                }
            } label: {
                SidebarGroupHeader(
                    icon: icon, appIcon: appIcon,
                    name: name, count: records.count, expanded: expanded)
            }
            .buttonStyle(.plain)
        }
    }

    /// Claude, Codex and Cursor always appear as import sources — even at
    /// count 0 — so Cursor is never hidden behind “only sources we found”.
    private var importSources: [SessionSource] { [.claude, .codex, .cursor, .bundle] }

    /// One source-filter pill: icon + label + count, accent-highlighted
    /// while active. `source == nil` is the "All" pill.
    private func sourcePill(source: SessionSource?, label: String,
                            icon: String, count: Int) -> some View {
        let isActive = sourceFilter == source
        let tint = source.map(sourceTint) ?? Theme.info
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                sourceFilter = source
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .accessibilityHidden(true)
                    .font(.caption2.weight(.semibold))
                Text(label)
                    .font(.caption2.weight(.semibold))
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textTertiary)
            }
            .foregroundStyle(isActive ? tint : Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background(isActive ? Theme.wash(tint) : Theme.surfaceInset.opacity(0.62),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(
                isActive ? Theme.washBorder(tint) : Color.clear,
                lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityLabel("\(label), \(count) chats")
    }

    /// Active source filter for the Imported tab: nil = all tools.
    @State private var sourceFilter: SessionSource?

    /// Which imported-project groups are collapsed. Lives in view state —
    /// a convenience, not data worth persisting.
    @State private var collapsedProjects: Set<String> = []

    /// One imported-chat section: a project folder with its chats, newest
    /// activity first. Chats whose source recorded no folder (or just the
    /// home directory) collect under "No project folder" instead of faking
    /// a project name.
    private struct ProjectGroup: Identifiable {
        let key: String
        let name: String
        let icon: String
        let latest: Date
        let records: [SessionRecord]
        var id: String { key }
    }

    private func projectGroups(_ records: [SessionRecord]) -> [ProjectGroup] {
        var byPath: [String: [SessionRecord]] = [:]
        for record in records { byPath[record.workspacePath, default: []].append(record) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return byPath.map { path, group in
            let sorted = sortedTasks(group)
            let chatOnly = path.isEmpty
            let unknown = chatOnly || path == home
            return ProjectGroup(
                key: path,
                name: chatOnly
                    ? "Chat only"
                    : unknown ? "No project folder" : URL(fileURLWithPath: path).lastPathComponent,
                icon: chatOnly ? "bubble.left.and.bubble.right.fill" : unknown ? "tray" : "folder.fill",
                latest: sorted.first?.updatedAt ?? .distantPast,
                records: sorted)
        }
        .sorted { $0.latest > $1.latest }
    }

    /// One session row — tagged for List selection, marked and explained
    /// when its project folder is gone. `subtitle` prefixes the metadata
    /// line (used to badge the import source).
    private func sessionRow(_ record: SessionRecord, subtitle: String?) -> some View {
        let status = taskStatus(for: record)
        let workspaceAvailable = SessionStore.shared.validateWorkspaceBinding(record)
        return SessionHistoryRow(
            record: record,
            subtitle: subtitle,
            selected: selectedSessionID == record.id,
            pinned: pinnedSessionIDs.contains(record.id),
            sourceTint: sourceTint(record.source),
            statusTitle: taskStatusTitle(status),
            statusIcon: taskStatusIcon(status),
            statusColor: taskStatusColor(status),
            workspaceAvailable: workspaceAvailable,
            workspaceLabel: workspacePathLabel(record.workspacePath),
            onTogglePinned: { togglePinned(record) },
            onSelect: {
                NotificationCenter.default.post(name: .openAssistantHome, object: nil)
                selectedSessionID = record.id
            },
            onRename: { renameSession(record) },
            onDelete: { deleteSession(record) },
            onExport: { export(record, format: $0) },
            onExportTaskBundle: { exportTaskBundleFile(for: record) }
        )
    }

    private func renameSession(_ record: SessionRecord) {
        guard !(record.id == sessions.activeSessionID && sessions.isRunning) else {
            let alert = NSAlert()
            alert.messageText = "Finish the current answer first"
            alert.informativeText = "This chat can be renamed as soon as the model stops responding."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }

        let field = NSTextField(string: SessionTitle.display(for: record))
        field.placeholderString = "Chat name"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)

        let alert = NSAlert()
        alert.messageText = "Rename chat"
        alert.informativeText = "Choose a short name that is easy to find in history."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var updated = record
        updated.title = title
        updated.updatedAt = Date()
        guard case .success = SessionStore.shared.save(updated) else { return }
        if let index = recentSessions.firstIndex(where: { $0.id == updated.id }) {
            recentSessions[index] = updated
        }
        if updated.id == sessions.activeSessionID {
            _ = sessions.restore(updated)
        }
        NotificationCenter.default.post(
            name: .sessionTitleChanged,
            object: updated.id,
            userInfo: ["title": title])
    }

    private func deleteSession(_ record: SessionRecord) {
        let alert = NSAlert()
        alert.messageText = "Delete this chat?"
        alert.informativeText = "“\(SessionTitle.display(for: record))” will be removed from this Mac. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        SessionStore.shared.delete(record)
        recentSessions.removeAll { $0.id == record.id }
        pinnedSessionIDs.remove(record.id)
        if selectedSessionID == record.id || sessions.activeSessionID == record.id {
            sessions.newSession()
            selectedSessionID = nil
        }
    }

    private func sourceTint(_ source: SessionSource) -> Color {
        switch source {
        case .app: Theme.accent
        case .claude: Theme.warning
        case .codex: Theme.info
        case .cursor: Theme.accentBright
        case .bundle: Theme.success
        }
    }

    // MARK: Import

    /// Imports a portable task only after three explicit user choices: the
    /// bundle file, its passphrase, and the destination workspace. Decryption
    /// happens off the main actor because PBKDF2 is intentionally expensive.
    private func runTaskBundleImport() {
        guard !isImportingBundle else { return }
        guard !sessions.isRunning else {
            showTaskBundleError("Stop the active task before importing another task.")
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
            showTaskBundleError("The selected bundle could not be read.")
            return
        }

        isImportingBundle = true
        importStatus = "Decrypting task bundle…"
        Task.detached(priority: .userInitiated) {
            do {
                let bundle = try TaskBundleCodec.decode(data, passphrase: passphrase)
                await MainActor.run {
                    isImportingBundle = false
                    importStatus = nil
                    chooseWorkspaceForTaskBundle(bundle)
                }
            } catch {
                await MainActor.run {
                    isImportingBundle = false
                    importStatus = nil
                    showTaskBundleError(error.localizedDescription)
                }
            }
        }
    }

    /// A decrypted bundle never supplies its own destination. The selected
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
            selectedSessionID = record.id
            sidebarTab = .imported
            sourceFilter = .bundle
            importSummary = "Imported “\(record.title)” into \(workspace.lastPathComponent)."
            var preferences = AppPreferencesStore.shared.current
            preferences.lastSessionID = record.id
            preferences.lastWorkspacePath = workspace.standardizedFileURL.path
            preferences.workspaceBookmarkData = AppPreferencesStore.shared.bookmarkData(for: workspace)
            AppPreferencesStore.shared.save(preferences)
            Task { await reloadSessions() }
        } catch {
            showTaskBundleError(error.localizedDescription)
        }
    }

    private func showTaskBundleError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Task bundle import failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func runImport() {
        guard !isImporting else { return }
        isImporting = true
        importSummary = nil
        importSummaryIsWarning = false
        importStatus = "Scanning Claude, Codex and Cursor histories…"
        DiagnosticsCenter.shared.record(.import, "History import started")
        Task.detached(priority: .utility) {
            let report = ExternalHistoryImporter.importAll { progress in
                Task { @MainActor in
                    importStatus = Self.progressLabel(progress)
                }
            }
            await MainActor.run {
                isImporting = false
                importStatus = nil
                let details = [
                    "\(report.imported) imported",
                    "\(report.upToDate) up to date",
                    "\(report.skipped) skipped",
                    report.failed > 0 ? "\(report.failed) failed to save" : nil
                ].compactMap { $0 }.joined(separator: " · ")
                DiagnosticsCenter.shared.record(
                    .import,
                    report.failed > 0 ? "History import completed with save failures" : "History import finished",
                    detail: report.lastSaveError.map { "\(details) · Last error: \($0)" } ?? details,
                    level: report.failed > 0 || (report.imported == 0 && report.upToDate == 0 && report.skipped == 0) ? .warning : .info)
                if report.imported == 0 && report.upToDate == 0 && report.skipped == 0 && report.failed == 0 {
                    importSummary = "No Claude, Codex or Cursor histories found on this Mac."
                } else if report.failed > 0 {
                    importSummaryIsWarning = true
                    importSummary = report.lastSaveError.map {
                        "\(details). Last save error: \($0)"
                    } ?? details
                } else {
                    var parts: [String] = []
                    if report.imported > 0 { parts.append("\(report.imported) imported") }
                    if report.upToDate > 0 { parts.append("\(report.upToDate) up to date") }
                    importSummary = parts.joined(separator: " · ")
                }
                Task { await reloadSessions() }
            }
        }
    }

    /// One-line status for the import's live parser feedback.
    private static func progressLabel(_ progress: ImportProgress) -> String {
        switch progress.phase {
        case .scanning:
            return "Scanning \(progress.source.label) history…"
        case .parsing:
            let detail = progress.detail.isEmpty ? "" : " · \(progress.detail)"
            return "Parsing \(progress.source.label) \(progress.completed + 1)/\(max(progress.total, 1))\(detail)"
        case .saving:
            return "Saving imported sessions \(progress.completed + 1)/\(max(progress.total, 1))…"
        }
    }

    @State private var needsKeychainUnlock = false

    private func reloadSessions() async {
        // More than the visible ten: the Imported tab browses the same cache.
        let loaded = await Task.detached(priority: .utility) {
            Array(SessionStore.shared.loadAll().prefix(400))
        }.value
        needsKeychainUnlock = SessionCrypto.needsInteractiveUnlock
        pinnedSessionIDs = Set(AppPreferencesStore.shared.current.pinnedSessionIDs)
        recentSessions = loaded
        // Keep the highlight honest: the controller owns the active session;
        // a restore (or a run) elsewhere should show up here too.
        if let active = sessions.activeSessionID, selectedSessionID != active,
           recentSessions.contains(where: { $0.id == active }) {
            selectedSessionID = active
        }
    }

    /// Restore the picked session. Reports failure instead of no-op'ing so a
    /// click always has a visible outcome.
    private func selectSession(_ id: UUID?) {
        sessionRestoreError = nil
        guard let id else { return }
        // Snap-back after a failed restore re-fires selection with the
        // already-active session — don't rebuild its transcript twice.
        guard id != sessions.activeSessionID else { return }
        guard let record = recentSessions.first(where: { $0.id == id }) else { return }
        guard SessionStore.shared.validateWorkspaceBinding(record) else {
            sessionRestoreError = "Project folder no longer exists: \(record.workspacePath)"
            selectedSessionID = sessions.activeSessionID
            return
        }
        if sessions.restore(record) {
            // Persist so a relaunch lands back on this session too.
            var preferences = AppPreferencesStore.shared.current
            preferences.lastSessionID = record.id
            preferences.lastWorkspacePath = record.workspacePath.isEmpty ? nil : record.workspacePath
            if record.workspacePath.isEmpty {
                preferences.workspaceBookmarkData = nil
            }
            AppPreferencesStore.shared.save(preferences)
            // A stale load error from the previous workspace is not this one's.
            if case .failed = appState.enginePhase {
                appState.enginePhase = .idle
            }
        } else {
            sessionRestoreError = "Could not restore \"\(record.title)\"."
            selectedSessionID = sessions.activeSessionID
        }
    }

    // MARK: Export

    /// Rail button: export the chat currently on screen. The active session
    /// is persisted after every run, so the store always has the latest copy.
    private func exportCurrentChat() {
        let id = sessions.activeSessionID ?? SessionStore.shared.currentSessionID
        guard let id, let record = SessionStore.shared.load(id: id) else {
            let alert = NSAlert()
            alert.messageText = "Nothing to export yet"
            alert.informativeText = "Run a task first — the conversation is exported once it has been saved."
            alert.alertStyle = .informational
            alert.runModal()
            return
        }
        export(record, format: .markdown)
    }

    /// Save panel → write the rendered document. A failed write surfaces as
    /// an alert instead of a silent no-op.
    private func export(_ record: SessionRecord, format: SessionExporter.Format) {
        let panel = NSSavePanel()
        panel.title = "Export Chat"
        panel.prompt = "Export"
        panel.nameFieldStringValue = SessionExporter.suggestedName(for: record, format: format)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch format {
            case .markdown:
                try SessionExporter.markdown(for: record).write(to: url, atomically: true, encoding: .utf8)
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

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Open Project Folder"
        panel.message = "The agent works inside this folder and cannot escape it."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            // Transactional switch: stop the run, clear state, restore the
            // new workspace's last session — never leave a stale checkpoint
            // pointing at the old project.
            Task {
                await sessions.switchWorkspace(to: url)
                // A load error from the previous workspace is stale here.
                if case .failed = appState.enginePhase {
                    appState.enginePhase = .idle
                }
                var preferences = AppPreferencesStore.shared.current
                preferences.lastWorkspacePath = url.path
                preferences.workspaceBookmarkData = AppPreferencesStore.shared.bookmarkData(for: url)
                AppPreferencesStore.shared.save(preferences)
            }
        }
    }

    private func startChatOnly() {
        Task {
            await sessions.switchToChatOnly()
            selectedSessionID = nil
            sidebarTab = .sessions
            var preferences = AppPreferencesStore.shared.current
            preferences.lastWorkspacePath = nil
            preferences.workspaceBookmarkData = nil
            AppPreferencesStore.shared.save(preferences)
        }
    }
}

/// Collapsed chat navigation: a permanent 58-point silver utility rail with
/// 42-point interaction slots for New chat, Search, History/Expand, Bots, and
/// Settings. Names appear beside icons on hover/focus as overlays — the rail
/// never expands on pointer entry and never pushes content.
struct ChatRail: View {
    let showsBots: Bool
    var composerHeight: CGFloat = 224
    let onNewChat: () -> Void
    let onSearch: () -> Void
    let onExpand: () -> Void
    let onBots: () -> Void
    let onSettings: () -> Void

    @State private var hovered: String?
    @State private var tooltip: String?
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var focused: String?

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let name: String
    }

    private var items: [Item] {
        [
            Item(id: "new", icon: "square.and.pencil", name: "New chat"),
            Item(id: "search", icon: "magnifyingglass", name: "Search chats"),
            Item(id: "history", icon: "bubble.left.and.bubble.right", name: "Conversation history"),
            Item(id: "bots", icon: "person.2", name: "Bots"),
        ]
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(items) { item in
                railButton(item)
            }
            Spacer(minLength: 0)
            railButton(Item(id: "settings", icon: "gearshape", name: "Settings"))
            if !showsBots {
                ComposerHardwareSpine()
                    .frame(height: composerHeight)
                    .background(LinearGradient(
                        colors: [Instrument.silverTop, Instrument.silverMid, Instrument.silverLow],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .top) {
                        Rectangle().fill(Instrument.seamLight).frame(height: 1)
                    }
                    .padding(.top, 2)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, showsBots ? 10 : 0)
        .frame(width: SidebarMetrics.collapsedWidth)
        .frame(maxHeight: .infinity)
        .background {
            LinearGradient(colors: [Instrument.silverTop, Instrument.silverMid, Instrument.silverLow],
                           startPoint: .top, endPoint: .bottom)
                .overlay {
                    Rectangle()
                        .fill(ImagePaint(image: Image(nsImage: InstrumentComposer.grainImage), scale: 1))
                        .opacity(0.06)
                        .allowsHitTesting(false)
                }
                .ignoresSafeArea(.container, edges: [.bottom])
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Instrument.seam).frame(width: 0.75)
        }
        .overlayPreferenceValue(RailAnchors.self) { anchors in
            GeometryReader { proxy in
                if let tooltip, let anchor = anchors[tooltip] {
                    let center = proxy[anchor]
                    Text(tooltip)
                        .font(.app(size: 12.5, weight: .medium))
                        .foregroundStyle(Instrument.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Instrument.silverTop,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Instrument.seam, lineWidth: 0.75))
                        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                        .fixedSize()
                        .offset(x: SidebarMetrics.collapsedWidth + 8,
                                y: center.y - 13)
                        .allowsHitTesting(false)
                }
            }
            .allowsHitTesting(false)
        }
        .onHover { inside in
            if !inside { clearHover() }
        }
    }

    private func railButton(_ item: Item) -> some View {
        Button(action: { activate(item) }) {
            Image(systemName: item.icon)
                .font(.system(size: SidebarMetrics.railIcon, weight: .medium))
                .foregroundStyle(item.id == "bots" && showsBots
                                 ? Color.white
                                 : (hovered == item.id || focused == item.id
                                    ? Instrument.ink : Instrument.inkSecondary))
                .frame(width: SidebarMetrics.railFace, height: SidebarMetrics.railFace)
                .background(
                    item.id == "bots" && showsBots
                        ? AnyShapeStyle(Instrument.darkInsert)
                        : AnyShapeStyle(LinearGradient(
                            colors: [Instrument.silverTop, Instrument.silverLow],
                            startPoint: .top, endPoint: .bottom)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(item.id == "bots" && showsBots
                                  ? Color.white.opacity(0.12)
                                  : Instrument.seam.opacity(0.65), lineWidth: 0.75))
                .frame(width: SidebarMetrics.railTarget, height: SidebarMetrics.railTarget)
                .overlay(alignment: .leading) {
                    if item.id == "bots" && showsBots {
                        Capsule().fill(Instrument.accentOrange)
                            .frame(width: SidebarMetrics.railMarkerWidth,
                                   height: SidebarMetrics.railMarkerHeight)
                            .padding(.leading, SidebarMetrics.railMarkerInset)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = item.id
                hoverTask?.cancel()
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, hovered == item.id else { return }
                    tooltip = item.name
                }
            } else if hovered == item.id {
                clearHover()
            }
        }
        .focused($focused, equals: item.id)
        .onChange(of: focused) { _, newValue in
            tooltip = newValue.flatMap { id in items.first { $0.id == id }?.name }
        }
        .anchorPreference(key: RailAnchors.self, value: .center) { [item.name: $0] }
        .help(item.name)
        .accessibilityLabel(item.name)
    }

    private func clearHover() {
        hovered = nil
        hoverTask?.cancel()
        hoverTask = nil
        if focused == nil { tooltip = nil }
    }

    private func activate(_ item: Item) {
        switch item.id {
        case "new": onNewChat()
        case "search": onSearch()
        case "history": onExpand()
        case "bots": onBots()
        default: onSettings()
        }
    }

    private struct RailAnchors: PreferenceKey {
        static let defaultValue: [String: Anchor<CGPoint>] = [:]
        static func reduce(value: inout [String: Anchor<CGPoint>],
                           nextValue: () -> [String: Anchor<CGPoint>]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }
}

/// A session-list leaf with narrow display inputs, so updates to the sidebar
/// header and other session groups do not re-evaluate every row's content.
struct SessionHistoryRow: View {
    let record: SessionRecord
    let subtitle: String?
    let selected: Bool
    let pinned: Bool
    let sourceTint: Color
    let statusTitle: String?
    let statusIcon: String
    let statusColor: Color
    let workspaceAvailable: Bool
    let workspaceLabel: String
    let onTogglePinned: () -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onExport: (SessionExporter.Format) -> Void
    let onExportTaskBundle: () -> Void
    @State private var isHovered = false
    @FocusState private var actionsFocused: Bool

    /// Metadata stays reachable (context menu, ellipsis, tooltip) but never
    /// competes with the title on every row.
    private var metadataLine: String {
        var parts: [String] = []
        if let subtitle { parts.append(subtitle) }
        parts.append("\(record.messages.count) messages")
        parts.append(SessionTitle.compactAge(record.updatedAt))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Text(SessionTitle.display(for: record))
                    .font(.appUI(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(workspaceAvailable
                                     ? Instrument.ink : Instrument.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                // Reserved trailing slot: state dot when actionable, plus an
                // ellipsis that appears on hover/focus. Space is always
                // reserved so titles never reflow when controls appear.
                HStack(spacing: 6) {
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Instrument.inkSecondary)
                            .accessibilityLabel("Pinned")
                    }
                    if let statusTitle {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(statusTitle)
                    }
                    Menu {
                        rowMenu
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Instrument.inkSecondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .focused($actionsFocused)
                    .opacity(isHovered || selected || actionsFocused ? 1 : 0)
                    .accessibilityLabel("Conversation actions")
                }
                .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, SidebarMetrics.rowPadding)
            .frame(minHeight: SidebarMetrics.rowHeight)
            .background(
                selected ? Instrument.recessFill.opacity(0.98)
                    : isHovered ? Theme.libraryRowHover : Color.clear,
                in: RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius,
                                     style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius,
                                 style: .continuous)
                    .strokeBorder(selected ? Instrument.seam.opacity(0.9) : Color.clear,
                                  lineWidth: 0.75))
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(Instrument.accentOrange)
                        .frame(width: 2, height: 16)
                        .padding(.leading, 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            rowMenu
        }
        .listRowInsets(EdgeInsets(top: 1, leading: SidebarMetrics.inset,
                                  bottom: 1, trailing: SidebarMetrics.inset))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .disabled(!workspaceAvailable)
        .help(workspaceAvailable
            ? "\(SessionTitle.display(for: record)) — \(metadataLine)"
            : "Project folder missing: \(record.workspacePath)")
        .accessibilityValue(
            "\(pinned ? "Pinned. " : "")\(statusTitle ?? "Completed"). \(metadataLine)")
    }

    @ViewBuilder
    private var rowMenu: some View {
        Button(pinned ? "Unpin task" : "Pin task", action: onTogglePinned)
        Button("Rename chat…", action: onRename)
        Divider()
        Button("Export as Markdown…") { onExport(.markdown) }
        Button("Export as JSON…") { onExport(.json) }
        Button("Export task bundle…", action: onExportTaskBundle)
        Divider()
        Button("Delete chat", role: .destructive, action: onDelete)
    }
}

/// Sidebar identity, primary actions, history controls, and the compact queue
/// lane. It receives only the values it renders plus closures for mutations,
/// keeping the session list isolated from header-only state changes.
struct SidebarHeaderView: View {
    let workspaceURL: URL?
    let sidebarTab: SidebarHistoryTab
    @Binding var historySearch: String
    let queuedTasks: [QueuedAgentTask]
    let isImporting: Bool
    let isImportingBundle: Bool
    let onChooseWorkspace: () -> Void
    let onChatOnly: () -> Void
    let onImport: () -> Void
    let onImportTaskBundle: () -> Void
    let onRefresh: () -> Void
    let onSelectTab: (SidebarHistoryTab) -> Void
    let onRunNext: () -> Void
    let onRemoveQueuedTask: (UUID) -> Void
    let onClose: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            identityRow
            searchField
            if !queuedTasks.isEmpty {
                queueSummary
            }
        }
        .padding(.horizontal, SidebarMetrics.inset)
        .padding(.top, SidebarMetrics.inset)
        .padding(.bottom, 10)
        .background(Color.clear)
        .onReceive(NotificationCenter.default.publisher(for: .focusChatSearch)) { _ in
            presentSearch()
        }
        .onExitCommand {
            if !historySearch.isEmpty {
                historySearch = ""
            } else {
                searchFocused = false
                onClose()
            }
        }
    }

    /// Conversation-browser identity. Top-level navigation belongs to the rail.
    private var identityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("CHATS")
                    .font(.appUI(size: 10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Instrument.engraved)
                Spacer(minLength: 0)
                importFilterButton
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Instrument.inkSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InstrumentPressStyle())
                .help("Close history")
                .accessibilityLabel("Close history")
            }
            Menu {
                Button("Open project…", action: onChooseWorkspace)
                Button("Chat without a project", action: onChatOnly)
                Divider()
                Button("Import conversations…", action: onImport)
                    .disabled(isImporting)
                Button("Import task bundle…", action: onImportTaskBundle)
                    .disabled(isImportingBundle)
                Button("Refresh history", action: onRefresh)
            } label: {
                HStack(spacing: 5) {
                    workspaceMark
                    Text(workspaceURL?.lastPathComponent ?? "No project")
                        .font(.appUI(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Instrument.inkSecondary)
            }
            .menuStyle(.borderlessButton)
            .help(workspaceURL?.path ?? "Conversation workspace and import actions")
            .accessibilityLabel("Workspace: \(workspaceURL?.lastPathComponent ?? "Chat only")")
        }
    }

    /// Imported conversations live behind a compact filter toggle (the
    /// control selects the imported library; the import command itself stays
    /// in the workspace menu / empty states). Active state is visible.
    private var importFilterButton: some View {
        Button {
            onSelectTab(sidebarTab == .imported ? .sessions : .imported)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sidebarTab == .imported
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12, weight: .medium))
                if sidebarTab == .imported {
                    Text("Imported")
                        .font(.app(size: 11, weight: .medium ))
                }
            }
            .foregroundStyle(sidebarTab == .imported
                             ? Instrument.ink : Instrument.inkSecondary)
            .frame(height: 26)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lfHoverLift()
        .help(sidebarTab == .imported
              ? "Showing imported conversations — click to return to your chats"
              : "Filter to imported conversations")
        .accessibilityLabel(sidebarTab == .imported
                            ? "Imported filter active" : "Show imported conversations")
    }

    private var workspaceMark: some View {
        Group {
            if let workspaceURL, let icon = AppIconLookup.workspace(workspaceURL.path) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: workspaceURL == nil ? "bubble.left.and.bubble.right" : "folder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }


    private var searchField: some View {
        VampSearchField(placeholder: "Search chats",
                        text: $historySearch,
                        focus: $searchFocused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search chat history")
    }

    private func presentSearch() {
        DispatchQueue.main.async {
            searchFocused = true
        }
    }

    private var queueSummary: some View {
        let first = queuedTasks[0]
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.app(size: 11, weight: .semibold ))
                    .foregroundStyle(Theme.info)
                Text(queuedTasks.count == 1 ? "1 task in queue" : "\(queuedTasks.count) tasks in queue")
                    .font(.app(size: 11, weight: .semibold ))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 4)
                Button("Run next", action: onRunNext)
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accentText)
                    .help("Start the next queued task when a model is ready")
            }

            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(queueStateColor(first.state))
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(first.message)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Text(first.phase ?? first.state.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(queueStateColor(first.state))
                }
                Spacer(minLength: 0)
            }

            if queuedTasks.count > 1 {
                Menu {
                    ForEach(queuedTasks.prefix(5)) { task in
                        Button("Remove \(queueTaskMenuTitle(task))") {
                            onRemoveQueuedTask(task.id)
                        }
                    }
                } label: {
                    Text("Manage queued tasks…")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Theme.wash(Theme.info), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Theme.washBorder(Theme.info), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(queuedTasks.count) queued tasks")
    }

    private func queueTaskMenuTitle(_ task: QueuedAgentTask) -> String {
        let text = task.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = text.count > 32 ? String(text.prefix(32)) + "…" : text
        return "“\(short)”"
    }

    private func queueStateColor(_ state: QueuedTaskState) -> Color {
        switch state {
        case .awaitingApproval, .awaitingQuestion, .awaitingPlan:
            Theme.warning
        case .running:
            Theme.accent
        case .paused, .stopped:
            Theme.textTertiary
        case .queued:
            Theme.info
        case .completed:
            Theme.success
        case .failed:
            Theme.danger
        }
    }
}

struct ActiveModelRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch appState.enginePhase {
            case .idle:
                Label("No model loaded", systemImage: "cpu")
                    .foregroundStyle(Theme.textSecondary)
            case .loading(let name):
                Label("Loading \(name)…", systemImage: "hourglass")
                    .foregroundStyle(Theme.warning)
            case .ready(let name):
                Label(name, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.success)
                if let tps = appState.lastEngineStats.tokensPerSecond {
                    Text(String(format: "%.1f tokens/s", tps))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            case .failed(let reason):
                Label("Load failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                // Stale errors must not persist: dismiss returns to idle so a
                // fixed/downloaded model can be loaded without relaunching.
                Button("Dismiss") {
                    appState.enginePhase = .idle
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}
