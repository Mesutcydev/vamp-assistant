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
    /// Width of the main content region, measured by the hero's background
    /// probe and used only to size the composer.
    @State private var heroRegionWidth: CGFloat = 900

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
                ComposerView(store: composerStore)
                    .environmentObject(controller)
            }
        }
        .background { AtmosphereBackground(intensity: isEmptyConversation ? .home : .conversation) }
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
                .accessibilityHidden(true)
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
    @State private var cachedRows: [TranscriptRowModel] = []

    /// Cursor/ChatGPT-style transcript: a centered content column (never
    /// edge-to-edge prose), grouped tool steps, avatar-led assistant output.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if controller.transcript.isEmpty && controller.streamingText.isEmpty {
                        emptyState
                    }
                    ForEach(cachedRows) { row in
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
                            onNewChat: controller.newSession,
                            onDismiss: controller.dismissFinish)
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
            .onAppear {
                cachedRows = Self.makeDisplayRows(controller.transcript)
            }
            .onChange(of: controller.transcript) { _, transcript in
                cachedRows = Self.makeDisplayRows(transcript)
                // Activity rows can arrive several times per second. Avoid
                // animating the entire stack's height for every tool event.
                scrollToLatest(proxy)
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
            Spacer(minLength: Spacing.xl)

            VStack(spacing: Spacing.lg) {
                VStack(spacing: Spacing.md) {
                    Text("VAMP ASSISTANT")
                        .font(AppFont.homeWordmark)
                        .tracking(2.4)
                        .foregroundStyle(Theme.textPrimary)
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }

                Text("Ask anything, browse the web, control your Mac with permission, or open a project when you want Code.")
                    .font(AppFont.homeInvitation)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 460)

                if let status = homeStatus {
                    Text(status)
                        .font(.app(size: 13, design: .serif))
                        .foregroundStyle(homeStatusTint)
                        .padding(.top, 2)
                }
            }

            // Hero rhythm: 16 title → subtitle, 32 subtitle → composer.
            // One gap, twice the other, instead of two unrelated numbers.
            Spacer().frame(height: 32)

            ComposerView(store: composerStore, placement: .home,
                         homeMaxWidth: ComposerMetrics.homeWidth(for: heroRegionWidth))
                .environmentObject(controller)

            Spacer(minLength: Spacing.xl)
        }
        .padding(.horizontal, 48)
        // Both spacers flex, so the hero group is mathematically centred in
        // the canvas. This reserved strip is the one optical correction:
        // half of it (32pt, ~4% of the canvas) lifts the group above true
        // centre, which a wordmark this heavy needs to look centred.
        .padding(.bottom, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Measure the MAIN CONTENT region the hero occupies, so the composer
        // proportion is a share of that region and never of the whole window.
        // Read from a background probe: the width it reports cannot depend on
        // anything the width feeds, so this settles in one pass.
        .background {
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size.width, initial: true) { _, width in
                        heroRegionWidth = width
                    }
            }
        }
        .opacity(homeVisible ? 1 : 0)
        .onAppear {
            if reduceMotion {
                homeVisible = true
            } else {
                withAnimation(.easeOut(duration: 0.28)) { homeVisible = true }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            remoteSessionsCornerButton
                .padding(.trailing, 18)
                .padding(.bottom, 16)
        }
    }

    private var homeStatus: String? {
        if case .failed = appState.enginePhase {
            return "The last model failed to load. Choose another in the composer."
        }
        if case .loading = appState.enginePhase {
            return "Loading model…"
        }
        return nil
    }

    private var homeStatusTint: Color {
        if case .failed = appState.enginePhase { return Theme.danger }
        return Theme.textTertiary
    }

    private var remoteSessionsCornerButton: some View {
        Button {
            NotificationCenter.default.post(name: .openRemoteAccess, object: nil)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .accessibilityHidden(true)
                    .font(.app(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(Theme.surface.opacity(0.92),
                                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.75))

                Circle()
                    .fill(appState.remoteSessionRunning ? Theme.success : Theme.textTertiary)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                    .padding(5)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .buttonStyle(LFPlainPressButtonStyle())
        .lfHoverLift()
        .help(appState.remoteSessionRunning
              ? "Remote Sessions — a session is running"
              : "Remote Sessions")
        .accessibilityLabel("Open Remote Sessions")
        .accessibilityValue(appState.remoteSessionRunning ? "A session is running" : "No session running")
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
                QuestionCard(
                    question: question,
                    choices: controller.pendingQuestionChoices
                ) { answer in
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
private enum TranscriptRowModel: Identifiable, Equatable {
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
    static func makeDisplayRows(
        _ transcript: [AgentSessionController.TranscriptItem]
    ) -> [TranscriptRowModel] {
        var rows: [TranscriptRowModel] = []
        var buffer: [AgentSessionController.TranscriptItem] = []
        func flush() {
            if !buffer.isEmpty {
                rows.append(.activity(buffer))
                buffer = []
            }
        }
        for item in transcript {
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
