import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Persisted draft

/// A conversation-owned draft. Missing attachments in legacy files decode as empty.
struct ComposerDraftState: Codable, Sendable, Equatable {
    var prompt: String = ""
    var selection = IntentSelection()
    var attachments: [ComposerAttachment]? = nil
}

// MARK: - Store

/// Single source of truth for the composer screen: the draft prompt, the
/// attachments, and the per-turn Intent (roles + focus) that prefixes the
/// outgoing message. Views never keep their own copy of this state.
///
/// Compared to the Intent Lattice it replaces: two binary chip rows instead
/// of a 48-cell matrix, no weights/muted states/superposition, and honest
/// token telemetry (≈ chars/4 against the model's real context window).
@MainActor
@Observable
final class ComposerStore {

    // MARK: Draft (editable)

    var prompt: String = "" {
        didSet {
            schedulePersist()
            // A paste can replace the draft with tens of thousands of
            // characters in one edit (and some native text paths deliver it
            // in a burst of edits). Recomputing token telemetry synchronously
            // makes each edit scan the entire String and briefly starves the
            // main thread, which presents as a white window. Coalesce the
            // derived work while the editor is settling; the prompt itself
            // remains live and editable throughout.
            scheduleEstimateRefresh()
        }
    }
    var attachments: [ComposerAttachment] = [] {
        didSet { schedulePersist(); refreshAvailability(); refreshResolvedFocus() }
    }
    var selection: IntentSelection = IntentSelection() {
        didSet { schedulePersist(); refreshResolvedFocus() }
    }

    // MARK: Derived (never stored twice)

    private(set) var focusAvailability: [FocusSource: FocusAvailability] = [:]
    private(set) var estimate = TokenEstimate(
        draftTokens: 0, intentTokens: 0, focusTokens: 0, attachmentTokens: 0,
        totalTokens: 0, historyTokens: 0, requestTokens: 0,
        contextWindow: nil, responseReserve: 4_096,
        historyMessageCount: 0, canCompact: false, utilization: nil)

    struct TokenEstimate: Sendable, Equatable {
        var draftTokens: Int
        var intentTokens: Int
        var focusTokens: Int
        var attachmentTokens: Int
        /// The current turn only. Kept separate so the UI can explain why a
        /// request is large without pretending the prompt is the whole chat.
        var totalTokens: Int
        /// Estimated tokens already persisted in the continuation session.
        var historyTokens: Int
        /// History plus the current turn, before the system prompt/tool
        /// envelope. This is the useful preflight number for the composer.
        var requestTokens: Int
        /// The loaded local model's context window; nil for remote engines
        /// (unknown → no percentage, per the honesty rule).
        var contextWindow: Int?
        var responseReserve: Int
        var historyMessageCount: Int
        var canCompact: Bool
        var utilization: Double?

        var shouldCompact: Bool {
            canCompact && (utilization ?? 0) >= 0.75
        }

        var isOverBudget: Bool {
            (utilization ?? 0) >= 1
        }
    }

    /// Resolved focus content, cached so typing never shells out to git.
    /// Refreshed when the selection/attachments/workspace change; re-resolved
    /// fresh at send time.
    private(set) var resolvedFocusCache: [FocusSource: String] = [:]

    // MARK: Private

    private var controller: AgentSessionController?
    private var appState: AppState?
    private var cancellables: Set<AnyCancellable> = []
    private var persistTask: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?
    private nonisolated static let draftWriteQueue = DispatchQueue(label: "com.beetcode.draft-writes", qos: .utility)
    private var workspaceKey: String?
    private var draftKey: String?
    private var windowID = "main"
    private var draftSessionID: UUID?
    private var memoryDrafts: [String: ComposerDraftState] = [:]
    private var lastEstimateRefresh = Date.distantPast
    private var cachedHistoryTokens = 0
    private var cachedHistoryMessageCount = 0
    private var cachedCanCompact = false
    private var historyRefreshTask: Task<Void, Never>?
    /// Snapshot of the published engine phase used by the synchronous
    /// send validation. This prevents the Run button from retaining the
    /// initial Loading state after a large local model finishes paging in.
    private(set) var currentEnginePhase: AppState.EnginePhase = .idle
    /// Captured persist that has not yet hit disk. Flushed synchronously on
    /// workspace switch so a cancelled debounce cannot drop the old draft.
    private var pendingPersist: (url: URL, state: ComposerDraftState)?
    private var isLoadingDraft = false

    // MARK: Wiring

    func attach(controller: AgentSessionController, appState: AppState) {
        guard self.controller !== controller || self.appState !== appState else { return }
        flushDraft()
        cancellables.removeAll()
        self.controller = controller
        self.appState = appState
        currentEnginePhase = appState.enginePhase

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.flushDraft() }
            .store(in: &cancellables)

        // Subscribe to the phase publisher itself so the composer invalidates
        // its own observation graph when an MLX load completes.
        appState.$enginePhase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                self.currentEnginePhase = phase
                self.recomputeEstimate()
            }
            .store(in: &cancellables)

        controller.$workspaceURL.combineLatest(controller.$activeSessionID)
            .sink { [weak self] workspace, sessionID in
                Task { @MainActor in self?.conversationDidChange(workspace: workspace, sessionID: sessionID) }
            }
            .store(in: &cancellables)

        // The estimate's denominator depends on the active model; throttled
        // so per-token objectWillChange storms can't recompute on every token.
        appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastEstimateRefresh) > 1 else { return }
                self.lastEstimateRefresh = now
                self.recomputeEstimate()
            }
            .store(in: &cancellables)

        // Session persistence is the source of truth for continuation
        // context. Refresh it when the controller changes, but keep the
        // actual disk read out of the prompt's per-keystroke path.
        controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // `objectWillChange` is emitted in willSet for @Published
                // properties. Defer one run-loop turn so a session selection
                // has finished updating `currentSessionID` before we read it.
                self.historyRefreshTask?.cancel()
                self.historyRefreshTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled, let self else { return }
                    self.refreshHistoryEstimate()
                    self.recomputeEstimate()
                }
            }
            .store(in: &cancellables)

        conversationDidChange(workspace: controller.workspaceURL, sessionID: controller.activeSessionID)
    }

    // MARK: Availability — driven by REAL application state

    func configureWindow(_ id: String) { windowID = id }

    func flushDraft() {
        if let draftKey { memoryDrafts[draftKey] = draftSnapshot }
        flushPersistNow()
    }

    func beginNewConversation() {
        flushDraft()
        isLoadingDraft = true
        prompt = ""
        attachments = []
        selection = IntentSelection()
        isLoadingDraft = false
        draftSessionID = nil
        // A second New Chat while already on an unsent chat must not restore
        // that same window slot's old draft from the queued session publisher.
        draftKey = "window.\(windowID).\(workspaceKey ?? "chat-only")"
        memoryDrafts[draftKey!] = draftSnapshot
        schedulePersist()
    }

    private var draftSnapshot: ComposerDraftState {
        ComposerDraftState(prompt: prompt, selection: selection, attachments: attachments)
    }

    private func conversationDidChange(workspace: URL?, sessionID: UUID?) {
        guard workspace?.path == controller?.workspaceURL?.path,
              sessionID == controller?.activeSessionID else { return }
        let workspacePath = workspace?.standardizedFileURL.path ?? "chat-only"
        let key = sessionID.map { "conversation.\($0.uuidString)" }
            ?? "window.\(windowID).\(workspacePath)"
        guard key != draftKey else { return }
        let newlyStarted = draftKey != nil && draftSessionID == nil && sessionID != nil
            && workspaceKey == workspacePath && controller?.isRunning == true
        flushDraft()
        workspaceKey = workspacePath
        draftKey = key
        draftSessionID = sessionID
        if newlyStarted {
            // The first send assigns a session ID. Carry its already-cleared
            // composer forward instead of restoring another conversation.
            schedulePersist()
        } else { loadDraft(for: workspace) }
        refreshAvailability()
        refreshResolvedFocus()
        refreshHistoryEstimate()
    }

    func refreshAvailability() {
        let workspace = controller?.workspaceURL
        let fm = FileManager.default
        var map: [FocusSource: FocusAvailability] = [:]

        map[.files] = attachments.isEmpty
            ? .unavailable(reason: "Attach a file first — @files quotes the attachments of this message.")
            : .available

        guard let workspace else {
            map[.git] = .unavailable(reason: "Open a project folder first.")
            map[.docs] = .unavailable(reason: "Open a project folder first.")
            map[.codebase] = .unavailable(reason: "Open a project folder first.")
            focusAvailability = map
            return
        }

        map[.git] = ContextResolvers.isGitRepo(workspace)
            ? .available
            : .unavailable(reason: "The selected folder is not a git repository.")
        let hasDocs = fm.fileExists(atPath: workspace.appendingPathComponent("docs").path)
            || !ContextResolvers.markdownNames(in: workspace).isEmpty
        map[.docs] = hasDocs
            ? .available
            : .unavailable(reason: "No README or docs/*.md found in this workspace.")
        map[.codebase] = .available

        focusAvailability = map
    }

    func availability(for source: FocusSource) -> FocusAvailability {
        focusAvailability[source] ?? .unavailable(reason: "Unavailable.")
    }

    // MARK: Selection mutations — binary, availability-gated for focus

    func toggleRole(_ role: IntentRole) {
        if selection.roles.contains(role) {
            selection.roles.remove(role)
        } else {
            selection.roles.insert(role)
        }
    }

    func toggleFocus(_ source: FocusSource) {
        if selection.focus.contains(source) {
            selection.focus.remove(source)
        } else {
            guard availability(for: source).isAvailable else { return }
            selection.focus.insert(source)
        }
    }

    /// Presets replace the role selection; focus is workspace-dependent and
    /// left untouched.
    func applyPreset(_ preset: IntentPreset) {
        selection.roles = Set(preset.roles)
    }

    func clearIntent() {
        selection = IntentSelection()
    }

    /// One attachment entry point for the picker, pasteboard, and Finder
    /// drops. It ignores folders and duplicates and keeps each turn bounded
    /// to eight files so every input path behaves the same way.
    @discardableResult
    func addAttachments(_ urls: [URL], limit: Int = 8) -> Int {
        guard attachments.count < limit else { return 0 }

        var knownPaths = Set(attachments.map { $0.url.standardizedFileURL.path })
        var accepted = 0
        for url in urls where attachments.count < limit {
            let standardized = url.standardizedFileURL
            guard standardized.isFileURL,
                  (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                  knownPaths.insert(standardized.path).inserted
            else { continue }

            attachments.append(ComposerAttachment(url: standardized))
            accepted += 1
        }
        return accepted
    }

    // MARK: Resolved focus content

    /// Fresh resolution — used at send time so the injected content reflects
    /// the workspace as it is right now.
    func resolvedFocus(_ source: FocusSource) -> String {
        switch source {
        case .files:
            return attachments.map(\.name).joined(separator: ", ")
        case .git:
            guard let workspace = controller?.workspaceURL else { return "" }
            return ContextResolvers.gitContext(workspace: workspace)
        case .docs:
            guard let workspace = controller?.workspaceURL else { return "" }
            return ContextResolvers.documentationContext(workspace: workspace)
        case .codebase:
            guard let workspace = controller?.workspaceURL else { return "" }
            return ContextResolvers.codebaseContext(workspace: workspace)
        }
    }

    /// Cache refresh: recomputes only the selected sources, and only fires on
    /// selection/attachment/workspace changes — never on prompt keystrokes,
    /// so typing can never spawn a git process.
    private func refreshResolvedFocus() {
        var cache: [FocusSource: String] = [:]
        for source in selection.orderedFocus {
            cache[source] = resolvedFocus(source)
        }
        resolvedFocusCache = cache
        recomputeEstimate()
    }

    // MARK: Token estimate (honest: ≈ chars/4 against the real window)

    private func recomputeEstimate() {
        let draftTokens = IntentTokens.estimate(prompt)
        let intentTokens = selection.orderedRoles.reduce(0) { $0 + IntentTokens.estimate($1.instruction) }
        let focusTokens = selection.orderedFocus.reduce(0) { $0 + IntentTokens.estimate(resolvedFocusCache[$1] ?? "") }
        let attachmentTokens = attachments.reduce(0) { $0 + estimatedAttachmentTokens($1) }
        let total = draftTokens + intentTokens + focusTokens + attachmentTokens
        let requestTokens = cachedHistoryTokens + total

        // The engine's REAL launched window (GGUF fits ctx to RAM) is the
        // honest denominator; the catalog value is the fallback.
        let window = appState?.effectiveContextWindow ?? appState?.activeModel?.contextWindow
        // The denominator is the window minus the response reserve; when the
        // window is unknown (remote engine) there is no percentage, by design.
        let reserve = 4_096
        let utilization = window.map { Double(requestTokens) / Double(max(1, $0 - reserve)) }

        estimate = TokenEstimate(
            draftTokens: draftTokens, intentTokens: intentTokens,
            focusTokens: focusTokens, attachmentTokens: attachmentTokens,
            totalTokens: total,
            historyTokens: cachedHistoryTokens,
            requestTokens: requestTokens,
            contextWindow: window,
            responseReserve: reserve,
            historyMessageCount: cachedHistoryMessageCount,
            canCompact: cachedCanCompact,
            utilization: utilization)
    }

    /// Coalesce prompt-driven telemetry so large pastes never turn a single
    /// edit into repeated full-string scans on the main actor. Other state
    /// changes still recompute synchronously; this path is only for typing.
    private func scheduleEstimateRefresh() {
        guard estimateTask == nil else { return }
        estimateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            self.estimateTask = nil
            self.recomputeEstimate()
        }
    }

    /// Reads only the persisted continuation record. The active loop owns its
    /// private mutable record; after a run finishes it is persisted and the
    /// controller publishes a change, so the next composer estimate includes
    /// the actual history the next request will replay.
    private func refreshHistoryEstimate() {
        guard let seed = controller?.restoredSeed else {
            cachedHistoryTokens = 0
            cachedHistoryMessageCount = 0
            cachedCanCompact = false
            return
        }
        cachedHistoryTokens = seed.messages.reduce(0) { total, message in
            total + ContextCompactor.estimateTokens(message.content)
        }
        cachedHistoryMessageCount = seed.messages.count
        cachedCanCompact = seed.messages.contains { $0.role == .toolResult }
    }

    /// Matches what the send pipeline actually injects: text attachments are
    /// quoted up to a 16 KB cap (larger files degrade to a path note), and
    /// images contribute their vision description.
    private func estimatedAttachmentTokens(_ attachment: ComposerAttachment) -> Int {
        if attachment.isImage { return 300 }
        let size = (try? FileManager.default.attributesOfItem(atPath: attachment.url.path))?[.size] as? Int
        guard let size, size > 0 else { return 25 }
        return size < 16_384 ? max(1, (size + 3) / 4) : 25
    }

    // MARK: Validation + send

    /// The single reason the composer can't send right now, or nil. Slash
    /// commands bypass this entirely (they run locally).
    var sendBlocker: String? {
        if case .loading = currentEnginePhase { return "Model is loading…" }
        // An external harness brings its own model.
        if appState?.isModelReady != true, SettingsStore.shared.selectedHarness == nil {
            return "Choose a model to run"
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Describe the task first" }
        return nil
    }

    var canSend: Bool {
        sendBlocker == nil && controller?.isRunning == false
    }

    var canQueue: Bool {
        sendBlocker == nil
            && controller?.isRunning == true
            && controller?.activeSessionID != nil
            && attachments.isEmpty
    }

    var canSteer: Bool { canQueue }

    var runningActionBlocker: String? {
        guard controller?.isRunning == true,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        if !attachments.isEmpty {
            return "Attachments can be sent after this turn finishes; queue or steer with text only."
        }
        return nil
    }

    /// A compact action is offered only when the persisted history contains
    /// tool output that the compactor can actually collapse.
    var canCompactHistory: Bool {
        cachedCanCompact && controller?.isRunning == false
    }

    /// Slash → local command; otherwise compose the intent block and dispatch
    /// the real run. A successful dispatch is one-shot: prompt, attachments,
    /// and the intent selection all clear.
    @discardableResult
    func send() -> Bool {
        guard !ProcessInfo.processInfo.arguments.contains("--design-preview") else { return false }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        if text.hasPrefix("/") {
            guard let controller, controller.handleSlash(text) else { return false }
            prompt = ""
            return true
        }

        guard let controller, canSend else { return false }
        controller.clearRemoteRunOptions()
        let composed = IntentComposer.compose(selection: selection, draft: text) { [weak self] source in
            self?.resolvedFocus(source) ?? ""
        }
        let outgoing = attachments
        controller.send(composed, attachments: outgoing)
        prompt = ""
        attachments = []
        selection = IntentSelection()
        return true
    }

    /// The keyboard and primary composer action remain useful during a run:
    /// an ordinary submit becomes a durable follow-up instead of being lost.
    @discardableResult
    func submit() -> Bool {
        guard !ProcessInfo.processInfo.arguments.contains("--design-preview") else { return false }
        if controller?.isRunning == true {
            return queue()
        }
        return send()
    }

    @discardableResult
    func queue() -> Bool {
        guard !ProcessInfo.processInfo.arguments.contains("--design-preview") else { return false }
        guard let controller,
              let appState,
              let sessionID = controller.activeSessionID,
              canQueue,
              let message = composedDraft()
        else { return false }
        guard appState.enqueueLocalTask(sessionID: sessionID, message: message) != nil else {
            return false
        }
        clearAfterRunningAction()
        return true
    }

    @discardableResult
    func steer() -> Bool {
        guard let controller, canSteer, let message = composedDraft(),
              controller.steer(message)
        else { return false }
        clearAfterRunningAction()
        return true
    }

    private func composedDraft() -> String? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return IntentComposer.compose(selection: selection, draft: text) { [weak self] source in
            self?.resolvedFocus(source) ?? ""
        }
    }

    private func clearAfterRunningAction() {
        prompt = ""
        selection = IntentSelection()
    }

    // MARK: Persistence (per workspace, validated on restore)

    /// Test seam: redirect draft persistence into a temp dir so tests never
    /// touch the developer's real Application Support.
    static var overrideDraftsDir: URL?

    private var draftFileURL: URL? {
        // Visual fixtures and UI smoke tests must neither restore nor overwrite
        // a person's draft. Each preview starts from an in-memory composer.
        guard !ProcessInfo.processInfo.arguments.contains("--design-preview") else { return nil }
        guard let key = draftKey else { return nil }
        let dir: URL
        if let base = Self.overrideDraftsDir {
            dir = base.appendingPathComponent("ComposerDrafts", isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BeetCode/ComposerDrafts", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Stable filename from the conversation/window identity.
        let digest = key.unicodeScalars.reduce(into: UInt64(5381)) { acc, s in
            acc = (acc &* 33) &+ UInt64(s.value)
        }
        return dir.appendingPathComponent("draft-\(digest).json")
    }

    private func schedulePersist() {
        if isLoadingDraft { return }
        persistTask?.cancel()
        guard let url = draftFileURL else { return }
        let state = draftSnapshot
        pendingPersist = (url, state)
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Self.draftWriteQueue.async { Self.persist(state, to: url) }
            if pendingPersist?.url == url { pendingPersist = nil }
        }
    }

    /// Write any in-flight draft immediately. Called before rekeying so a
    /// workspace switch cannot cancel the debounce and lose the old file.
    private func flushPersistNow() {
        persistTask?.cancel()
        persistTask = nil
        if let pending = pendingPersist {
            Self.draftWriteQueue.sync { Self.persist(pending.state, to: pending.url) }
            pendingPersist = nil
        }
    }

    private nonisolated static func persist(_ state: ComposerDraftState, to url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func loadDraft(for workspace: URL?) {
        isLoadingDraft = true
        defer { isLoadingDraft = false }
        var restored = draftKey.flatMap { memoryDrafts[$0] }
        if restored == nil, let url = draftFileURL,
           let data = try? Data(contentsOf: url) {
            restored = try? JSONDecoder().decode(ComposerDraftState.self, from: data)
        }
        // Import the former workspace draft once, keeping the original file
        // intact. Each conversation subsequently saves under its own key.
        if restored == nil, let legacy = legacyDraftURL,
           !UserDefaults.standard.bool(forKey: "draft-migrated.\(legacy.lastPathComponent)"),
           let data = try? Data(contentsOf: legacy),
           let state = try? JSONDecoder().decode(ComposerDraftState.self, from: data) {
            restored = state
            UserDefaults.standard.set(true, forKey: "draft-migrated.\(legacy.lastPathComponent)")
        }
        prompt = restored?.prompt ?? ""
        selection = restored?.selection ?? IntentSelection()
        attachments = (restored?.attachments ?? []).filter { FileManager.default.fileExists(atPath: $0.url.path) }
        _ = workspace
    }

    private var legacyDraftURL: URL? {
        guard !ProcessInfo.processInfo.arguments.contains("--design-preview"), let workspaceKey,
              let current = draftFileURL else { return nil }
        let digest = workspaceKey.unicodeScalars.reduce(into: UInt64(5381)) {
            $0 = ($0 &* 33) &+ UInt64($1.value)
        }
        return current.deletingLastPathComponent().appendingPathComponent("draft-\(digest).json")
    }

}

// MARK: - AppState readiness bridge

extension AppState {
    var isModelReady: Bool {
        if case .ready = enginePhase { return true }
        return isRemoteActive || isCodexActive
    }
    var isModelLoading: Bool {
        if case .loading = enginePhase { return true }
        return false
    }
}
