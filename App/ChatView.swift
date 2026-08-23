import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var controller: AgentSessionController
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(controller: AgentSessionController) {
        self.controller = controller
    }

    /// Single source of truth for the composer (prompt, attachments, intent
    /// selection). Owned by ChatView so it survives view rebuilds; attached
    /// to the live controller/AppState in `.task`.
    @State private var composerStore = ComposerStore()
    @State private var sessionTitle = "New chat"
    @State private var homeVisible = false
    @State private var glowExpanded = false

    private var isEmptyConversation: Bool {
        controller.transcript.isEmpty
            && controller.streamingText.isEmpty
            && !controller.isRunning
            && !hasPendingGate
    }

    var body: some View {
        VStack(spacing: 0) {
            if isEmptyConversation {
                emptyState
            } else {
                ChatHeaderView(
                    title: sessionTitle,
                    phaseLabel: phaseLabel,
                    phaseTint: phaseTint,
                    canReview: controller.workspaceURL != nil,
                    onHome: controller.newSession,
                    onNewChat: controller.newSession)
                if controller.workspaceTrustNeeded {
                    workspaceTrustBanner
                }
                transcript
                if hasPendingGate {
                    pendingGate
                }
                Divider()
                ComposerView(store: composerStore)
                    .environmentObject(controller)
            }
        }
        .background { AtmosphereBackground() }
        .task {
            composerStore.attach(controller: controller, appState: appState)
        }
        .task(id: controller.activeSessionID) {
            let id = controller.activeSessionID
            let title = await Task.detached(priority: .utility) {
                guard let id, let record = SessionStore.shared.load(id: id) else {
                    return "New chat"
                }
                return SessionTitle.display(for: record)
            }.value
            guard !Task.isCancelled else { return }
            sessionTitle = title
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionTitleChanged)) { note in
            guard let id = note.object as? UUID,
                  id == controller.activeSessionID,
                  let title = note.userInfo?["title"] as? String else { return }
            sessionTitle = title
        }
        .onPasteCommand(of: [.png, .tiff, .jpeg, .fileURL]) { providers in
            handlePaste(providers)
        }
    }

    private var workspaceTrustBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Theme.warning)
            Text("This project contains MCP servers or hooks. Trust it before they can run.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Trust workspace") {
                controller.trustCurrentWorkspace()
            }
            .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.wash(Theme.warning))
    }

    private var phaseLabel: String {
        switch controller.currentPhase {
        case .idle: "Ready"
        case .planning: "Planning"
        case .awaitingPlanApproval: "Review plan"
        case .working: "Working"
        case .awaitingApproval: "Needs approval"
        case .awaitingQuestion: "Needs answer"
        case .verifying: "Verifying"
        case .finished: "Finished"
        }
    }

    private var phaseTint: Color {
        switch controller.currentPhase {
        case .awaitingApproval, .awaitingPlanApproval, .awaitingQuestion: Theme.warning
        case .working, .planning, .verifying: Theme.info
        case .finished: Theme.success
        case .idle: Theme.textTertiary
        }
    }

    // MARK: Transcript

    @State private var isPinnedToBottom = true

    /// Cursor/ChatGPT-style transcript: a centered content column (never
    /// edge-to-edge prose), grouped tool steps, avatar-led assistant output.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if controller.transcript.isEmpty && controller.streamingText.isEmpty {
                        emptyState
                    }
                    ForEach(displayRows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                    if controller.isRunning, !controller.liveReasoningText.isEmpty {
                        LiveReasoningCard(
                            text: controller.liveReasoningText,
                            phase: controller.currentPhase)
                    }
                    if !controller.streamingText.isEmpty {
                        StreamingCard(text: controller.streamingText)
                    } else if controller.isReasoningVisible && controller.isRunning {
                        ReasoningIndicator()
                    }
                    if let finish = controller.finishReason {
                        FinishBanner(
                            reason: finish,
                            summary: CompletionSnapshot.make(
                                transcript: controller.transcript),
                            onNewChat: controller.newSession)
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                // Centered content column: readable on ultra-wide windows,
                // but wide enough that ordinary windows aren't left with
                // dead space on both sides of the conversation.
                .frame(maxWidth: ContentColumn.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Pinned means the viewport bottom is within ~40 pt of the
                // content bottom — the user is following the output.
                let visibleMax = geometry.contentOffset.y + geometry.containerSize.height
                let contentHeight = geometry.contentSize.height
                return contentHeight - visibleMax < 40
            } action: { _, pinned in
                isPinnedToBottom = pinned
            }
            .onChange(of: controller.transcript.count) { _, _ in
                scrollToLatest(proxy, animated: true)
            }
            .onChange(of: controller.streamingText) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: controller.liveReasoningText) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: controller.isRunning) { _, running in
                if running { scrollToLatest(proxy, animated: true) }
            }
            .onChange(of: controller.finishReason) { _, reason in
                guard reason != nil else { return }
                // The completion card is inserted after the last streamed
                // token. Force one final follow pass so it is fully visible
                // instead of landing just below the viewport.
                isPinnedToBottom = true
                scrollToLatest(proxy, animated: true)
            }
            .overlay(alignment: .bottomTrailing) {
                if !isPinnedToBottom && (controller.isRunning || hasPendingGate) {
                    Button {
                        isPinnedToBottom = true
                        withAnimation { proxy.scrollTo("bottom") }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down.circle.fill")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            // Opaque capsule + hairline, same voice as the
                            // suggestion chips — no floating material.
                            .background(Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                            .shadow(color: Theme.cardShadow, radius: 6, y: 2)
                    }
                    .buttonStyle(.borderless)
                    .padding(12)
                }
            }
        }
    }

    /// Token batches can update the LazyVStack before the new row has a
    /// measured height. Deferring one main-queue turn makes the scroll target
    /// real before asking the proxy to move, which keeps streamed answers
    /// pinned without stealing the user's position when they scroll up.
    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool = false) {
        // During generation the content itself can briefly move the viewport
        // outside the bottom threshold before this callback runs. Treat an
        // active answer as follow mode so growing Markdown blocks cannot
        // accidentally disable auto-scroll.
        guard isPinnedToBottom || controller.isRunning else { return }
        DispatchQueue.main.async {
            guard self.isPinnedToBottom || self.controller.isRunning else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)

            ZStack {
                Circle()
                    .fill(Theme.accentBright.opacity(glowExpanded ? 0.22 : 0.10))
                    .frame(width: 102, height: 102)
                    .blur(radius: 18)
                    .scaleEffect(glowExpanded ? 1.14 : 1)
                if case .failed = appState.enginePhase {
                    emptyStateTile(
                        systemImage: "exclamationmark.triangle.fill",
                        fill: AnyShapeStyle(Theme.danger),
                        glow: Theme.danger)
                } else {
                    Image("BeetLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 46, height: 46)
                        .frame(width: 58, height: 58)
                        .background(.black, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .shadow(color: Theme.accent.opacity(0.55), radius: 17, y: 7)
                }
            }
            .padding(.bottom, 22)

            Text(homeHeadline)
                .font(.system(size: 27, weight: .semibold))
                .tracking(-0.45)
                .foregroundStyle(Theme.textPrimary)
            Text(homeBody)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 420)
                .padding(.top, 9)

            homeActions
                .padding(.top, 18)

            ComposerView(store: composerStore, placement: .home)
                .environmentObject(controller)
                .padding(.top, 26)

            if canSuggestPrompts {
                VStack(spacing: 10) {
                    suggestionRow(suggestions[0])
                    suggestionRow(suggestions[1])
                }
                .padding(.top, 20)
            }

            Spacer(minLength: 0)

            Text("Use /create-hook to extend the agent loop with custom scripts")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(homeVisible ? 1 : 0)
        .offset(y: homeVisible || reduceMotion ? 0 : 10)
        .onAppear {
            if reduceMotion {
                homeVisible = true
                glowExpanded = false
            } else {
                withAnimation(.easeOut(duration: 0.48)) { homeVisible = true }
                withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) {
                    glowExpanded = true
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            remoteSessionsCornerButton
                .padding(.trailing, 22)
                .padding(.bottom, 22)
        }
    }

    private var homeActions: some View {
        HStack(spacing: 10) {
            if controller.workspaceURL == nil {
                Button {
                    NotificationCenter.default.post(name: .openWorkspace, object: nil)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Open Project")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 15)
                    .frame(height: 48)
                    .background(Theme.surfaceInset.opacity(0.64),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Theme.hairline.opacity(0.46), lineWidth: 0.75))
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .lfHoverLift()
                .help("Open a project folder for coding tools")
            }
        }
        .frame(maxWidth: 460)
    }

    private var remoteSessionsCornerButton: some View {
        Button {
            NotificationCenter.default.post(name: .openRemoteAccess, object: nil)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Theme.accentGradient,
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
                    .shadow(color: Theme.accent.opacity(0.24), radius: 12, y: 5)

                Circle()
                    .fill(appState.remoteSessionRunning ? Theme.success : Theme.textTertiary)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                    .padding(5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(LFPlainPressButtonStyle())
        .lfHoverLift()
        .help("Remote Sessions")
        .accessibilityLabel("Open Remote Sessions")
    }

    private var homeHeadline: LocalizedStringKey {
        if case .failed = appState.enginePhase { return "Model failed to load" }
        if case .loading = appState.enginePhase { return "Loading model…" }
        if !hasRunnableModel { return "Choose a model to begin" }
        return "What should we build?"
    }

    private var homeBody: LocalizedStringKey {
        if case .failed = appState.enginePhase {
            return "Check the model or choose another engine, then try again."
        }
        if case .loading = appState.enginePhase {
            return "The composer unlocks when the engine is ready."
        }
        if !hasRunnableModel {
            return "Choose an API, Codex, or a downloaded local model to begin."
        }
        return "Describe a task in plain language. Reads run automatically — every edit and command is yours to approve."
    }

    private func emptyStateTile(
        systemImage: String, fill: AnyShapeStyle, glow: Color
    ) -> some View {
        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
            .fill(fill)
            .frame(width: 64, height: 64)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white))
            .shadow(color: glow.opacity(0.35), radius: 18, y: 6)
    }

    /// Label (chip text) + prompt (what actually goes in the composer).
    private struct Suggestion: Identifiable {
        let label: String
        let prompt: String
        let glyph: String
        var id: String { label }
    }

    private var suggestions: [[Suggestion]] {
        if controller.workspaceURL == nil {
            return [
                [
                    Suggestion(label: "Explain a concept",
                               prompt: "Explain a concept to me clearly, with a short example.",
                               glyph: "lightbulb"),
                    Suggestion(label: "Brainstorm ideas",
                               prompt: "Help me brainstorm ideas. Start by asking what outcome I want.",
                               glyph: "sparkles"),
                ],
                [
                    Suggestion(label: "Improve my writing",
                               prompt: "Help me improve a piece of writing while keeping my voice.",
                               glyph: "text.badge.checkmark"),
                    Suggestion(label: "Ask anything",
                               prompt: "I have a question I would like to think through with you.",
                               glyph: "bubble.left.and.questionmark.bubble.right"),
                ],
            ]
        }
        if looksLikeAppleProject {
            return [
                [
                    Suggestion(label: "Fix the failing build",
                               prompt: "Detect this Xcode or Swift project, run the build or tests, and fix whatever fails. Explain each fix.",
                               glyph: "wrench.and.screwdriver"),
                    Suggestion(label: "Run in Simulator",
                               prompt: "Build this iOS app, install it on a booted simulator, take a screenshot, and report what you see. Fix anything that fails.",
                               glyph: "iphone"),
                ],
                [
                    Suggestion(label: "Review recent changes",
                               prompt: "Review the current git diff. Summarize what changed, flag risks, and propose a test plan. Do not edit files unless I ask.",
                               glyph: "eye"),
                    Suggestion(label: "Add a feature",
                               prompt: "I want to add a new feature. First explore the codebase, then propose a plan before changing anything.",
                               glyph: "wand.and.stars"),
                ],
            ]
        }
        return [
            [
                Suggestion(label: "Explain this codebase",
                           prompt: "What does this project do? Walk me through the structure and the main entry points.",
                           glyph: "doc.text.magnifyingglass"),
                Suggestion(label: "Find bugs",
                           prompt: "Review this project for likely bugs and correctness problems. Report the top issues with file locations.",
                           glyph: "ladybug"),
            ],
            [
                Suggestion(label: "Fix the failing build",
                           prompt: "Run the build/tests and fix whatever fails. Explain each fix.",
                           glyph: "wrench.and.screwdriver"),
                Suggestion(label: "Add a feature",
                           prompt: "I want to add a new feature. First explore the codebase, then propose a plan before changing anything.",
                           glyph: "wand.and.stars"),
            ],
        ]
    }

    private var looksLikeAppleProject: Bool {
        guard let root = controller.workspaceURL else { return false }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return false
        }
        return items.contains { name in
            name.hasSuffix(".xcodeproj")
                || name.hasSuffix(".xcworkspace")
                || name == "Package.swift"
                || name == "project.yml"
        }
    }

    /// Suggestion chips make sense only when a run could actually start.
    private var hasRunnableModel: Bool {
        appState.activeModel != nil || appState.isRemoteActive || appState.isCodexActive
    }

    private var canSuggestPrompts: Bool {
        guard hasRunnableModel else { return false }
        switch appState.enginePhase {
        case .ready, .idle: return true
        case .loading, .failed: return false
        }
    }

    private var emptyHeadline: LocalizedStringKey {
        if case .failed = appState.enginePhase { return "Model failed to load" }
        if case .loading = appState.enginePhase { return "Loading model…" }
        if !hasRunnableModel { return "Choose a model" }
        if controller.workspaceURL == nil { return "Chat without a project" }
        return "Describe a task"
    }

    private var emptyBody: LocalizedStringKey {
        if case .failed = appState.enginePhase {
            return "Check the model file or pick another engine in the composer, then try again."
        }
        if case .loading = appState.enginePhase {
            return "The composer unlocks when the engine is ready."
        }
        if !hasRunnableModel {
            return "Pick an API key, Codex, or a downloaded local model to begin chatting."
        }
        if controller.workspaceURL == nil {
            return "Ask anything. Project files, commands, builds, and coding tools stay off until you open a folder."
        }
        return "Reads run automatically; every edit and command shows up here for approval."
    }

    @ViewBuilder
    private func suggestionRow(_ items: [Suggestion]) -> some View {
        HStack(spacing: 10) {
            ForEach(items) { suggestion in
                Button {
                    composerStore.prompt = suggestion.prompt
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: suggestion.glyph)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                        Text(suggestion.label)
                            .font(.caption)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(LFPlainPressButtonStyle())
                .lfHoverLift()
                .help(suggestion.prompt)
            }
        }
    }

    private var hasPendingGate: Bool {
        controller.pendingApproval != nil
            || controller.pendingQuestion != nil
            || controller.pendingPlan != nil
    }

    /// Approval, plan, and question cards stay above the composer so a long
    /// transcript cannot hide the gate the user has to act on.
    private var pendingGate: some View {
        // This is intentionally not a nested ScrollView. Nested scrolling made
        // approval cards compete with the transcript for wheel/trackpad events,
        // causing the chat to jump up and down while the agent streamed. Long
        // previews can still scroll naturally with the transcript, while the
        // action row remains visible in the fixed gate above the composer.
        VStack(alignment: .leading, spacing: 12) {
            if let approval = controller.pendingApproval {
                ApprovalCard(request: approval) { approved, always in
                    controller.approve(approved, always: always)
                }
            }
            if let question = controller.pendingQuestion {
                QuestionCard(question: question) { answer in
                    controller.answerQuestion(answer)
                }
            }
            if let plan = controller.pendingPlan {
                PlanCard(plan: plan) { feedback in
                    if let feedback {
                        controller.revisePlan(feedback)
                    } else {
                        controller.approvePlan()
                    }
                }
            }
        }
        .frame(maxWidth: ContentColumn.maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pending approval")
    }

    /// ⌘V: paste images (screenshots) or file URLs.
    private func handlePaste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        DispatchQueue.main.async {
                            composerStore.addAttachments([url])
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data, let image = NSImage(data: data) {
                        let dir = FileManager.default.temporaryDirectory
                            .appendingPathComponent("beetcode-paste", isDirectory: true)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let url = dir.appendingPathComponent("paste-\(Int(Date().timeIntervalSince1970)).png")
                        if let data = image.tiffRepresentation,
                           let bitmap = NSBitmapImageRep(data: data),
                           let png = bitmap.representation(using: .png, properties: [:]) {
                            try? png.write(to: url)
                            DispatchQueue.main.async {
                                composerStore.addAttachments([url])
                            }
                        }
                    }
                }
            }
        }
    }

}
// MARK: - Rows

/// One rendered transcript row. The agent's private work stream (reasoning,
/// tool calls, and tool results) is one calm activity surface; user and final
/// assistant messages remain the primary reading hierarchy.
private enum TranscriptRowModel: Identifiable {
    case user(AgentSessionController.TranscriptItem)
    case assistant(AgentSessionController.TranscriptItem)
    case activity([AgentSessionController.TranscriptItem])
    case meta(AgentSessionController.TranscriptItem)

    var id: String {
        switch self {
        case .user(let item), .assistant(let item), .meta(let item):
            return item.id.uuidString
        case .activity(let items):
            return "activity-" + (items.first?.id.uuidString ?? "empty")
        }
    }
}

private extension ChatView {
    /// Groups the flat transcript into display rows.
    var displayRows: [TranscriptRowModel] {
        var rows: [TranscriptRowModel] = []
        var buffer: [AgentSessionController.TranscriptItem] = []
        func flush() {
            if !buffer.isEmpty {
                rows.append(.activity(buffer))
                buffer = []
            }
        }
        for item in controller.transcript {
            switch item.kind {
            case .user:
                flush(); rows.append(.user(item))
            case .assistant:
                flush(); rows.append(.assistant(item))
            case .toolCall, .toolResult, .reasoning:
                buffer.append(item)
            case .checkpoint, .notice:
                flush(); rows.append(.meta(item))
            }
        }
        flush()
        return rows
    }

    @ViewBuilder
    func rowView(_ row: TranscriptRowModel) -> some View {
        switch row {
        case .user(let item):
            UserBubble(item: item)
        case .assistant(let item):
            AssistantMessage(item: item)
        case .activity(let items):
            AgentActivityCard(items: items)
        case .meta(let item):
            MetaRow(item: item)
        }
    }
}
