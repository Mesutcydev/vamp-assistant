import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var controller: AgentSessionController
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The composer store is owned by the window: the input well and the
    /// bottom key bar are different frame regions but share one draft.
    private let composerStore: ComposerStore
    init(controller: AgentSessionController, store: ComposerStore) {
        self.controller = controller
        self.composerStore = store
    }

    @State private var sessionTitle = "New chat"
    /// Width of the detail pane, recomputed when the sidebar or inspector
    /// opens, closes, or resizes — the content column follows it.
    @State private var paneWidth: CGFloat = 800

    private var isEmptyConversation: Bool {
        controller.transcript.isEmpty
            && controller.streamingText.isEmpty
            && !controller.isRunning
            && !hasPendingGate
    }

    var body: some View {
        // Measured, not pinned: a GeometryReader that forced its child to the
        // full proposed size also swallowed the window's top safe area, so the
        // transcript drew up through the title band.
        VStack(spacing: 0) {
            if controller.workspaceTrustNeeded {
                workspaceTrustBanner
            }
            if isEmptyConversation {
                WelcomeIdentityView(status: homeStatus,
                                    statusTint: homeStatusTint,
                                    statusIsLive: homeStatusIsLive)
            } else {
                transcript
                if hasPendingGate {
                    pendingGate
                }
            }
            bottomDock(workspaceWidth: paneWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
        // Keep an opaque themed backing at this boundary. During a streamed
        // answer SwiftUI can briefly re-measure the ScrollView while the
        // transcript grows; a transparent root exposes the native window's
        // white backing for a frame and reads as a full-screen flash.
        .background(Theme.workspaceCanvas)
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

    /// The middle of the device: transcript above, then the suggestion row
    /// (welcome only) and the writing well, both running nearly edge to edge
    /// so the middle reads as one continuous surface.
    private func bottomDock(workspaceWidth: CGFloat) -> some View {
        VStack(spacing: 10) {
            if isEmptyConversation && settings.showHomeSuggestions {
                SuggestionRow(store: composerStore, availableWidth: workspaceWidth)
                    .frame(width: min(ContentColumn.maxWidth, max(0, workspaceWidth - 32)))
            }
            ChatInputWell(store: composerStore)
                .frame(width: min(ContentColumn.maxWidth, max(0, workspaceWidth - 32)))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 18)
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

    /// Follow mode is separate from scroll geometry. Streaming changes the
    /// content height, and that must not be mistaken for the user scrolling
    /// away from the latest answer.
    @State private var followsLatest = true
    @State private var userIsInteracting = false
    @State private var scrollRequestGeneration = 0
    @State private var scrollWorkScheduled = false
    @State private var scrollNeedsFollowUp = false
    @State private var scrollAnimationRequested = false
    @State private var cachedRows: [TranscriptRowModel] = []

    private struct ScrollMetrics: Equatable {
        let offsetY: CGFloat
        let bottomDistance: CGFloat
    }

    private static let followThreshold: CGFloat = 64

    /// Cursor/ChatGPT-style transcript: a centered content column (never
    /// edge-to-edge prose), grouped tool steps, avatar-led assistant output.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if controller.transcript.isEmpty && controller.streamingText.isEmpty && !hasPendingGate {
                        TranscriptRuleLabel(text: "Waiting for the first message")
                    }
                    ForEach(cachedRows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                    if !controller.livePlan.isEmpty {
                        LivePlanCard(tasks: controller.livePlan)
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
                .padding(.top, 30)
                .padding(.bottom, 20)
                // A short conversation rests just above the writing well
                // instead of stranding itself at the top of a tall page.
                .containerRelativeFrame(.vertical, alignment: .bottom)
            }
            .background(Theme.workspaceCanvas)
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.top, for: .alignment)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offsetY: geometry.contentOffset.y,
                    bottomDistance: max(0, geometry.contentSize.height - geometry.visibleRect.maxY))
            } action: { previous, current in
                // Geometry changes caused by a streamed token are ignored.
                // Only an active drag is allowed to turn follow mode off.
                guard userIsInteracting else { return }
                if current.bottomDistance <= Self.followThreshold {
                    if !followsLatest { followsLatest = true }
                } else if current.offsetY < previous.offsetY - 1 {
                    followsLatest = false
                }
            }
            .onScrollPhaseChange { _, phase, context in
                let geometry = context.geometry
                let bottomDistance = max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
                switch phase {
                case .tracking, .interacting:
                    userIsInteracting = true
                    if bottomDistance <= Self.followThreshold, !followsLatest {
                        followsLatest = true
                    }
                case .idle:
                    userIsInteracting = false
                    if bottomDistance <= Self.followThreshold, !followsLatest {
                        followsLatest = true
                    }
                case .decelerating, .animating:
                    break
                @unknown default:
                    break
                }
            }
            .onAppear {
                cachedRows = Self.makeDisplayRows(controller.transcript)
                requestScroll(proxy)
            }
            .onChange(of: controller.transcript) { _, transcript in
                cachedRows = Self.makeDisplayRows(transcript)
                guard followsLatest else { return }
                requestScroll(proxy, animated: true)
            }
            .onChange(of: controller.streamingText) { _, _ in
                guard followsLatest else { return }
                requestScroll(proxy)
            }
            .onChange(of: controller.liveReasoningText) { _, _ in
                guard followsLatest else { return }
                requestScroll(proxy)
            }
            .onChange(of: controller.isRunning) { _, running in
                guard followsLatest else { return }
                if running { requestScroll(proxy, animated: true) }
            }
            .onChange(of: controller.finishReason) { _, reason in
                guard reason != nil else { return }
                followsLatest = true
                userIsInteracting = false
                requestScroll(proxy, animated: true)
            }
            .onChange(of: controller.activeSessionID) { _, _ in
                // A reused ChatView can retain scroll state from the prior
                // conversation. New sessions always open at their latest row.
                scrollRequestGeneration &+= 1
                scrollWorkScheduled = false
                scrollNeedsFollowUp = false
                scrollAnimationRequested = false
                followsLatest = true
                userIsInteracting = false
                cachedRows = Self.makeDisplayRows(controller.transcript)
                requestScroll(proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest && (controller.isRunning || hasPendingGate) {
                    Button {
                        followsLatest = true
                        userIsInteracting = false
                        requestScroll(proxy, animated: !reduceMotion, delay: 0)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 9, weight: .semibold))
                            Text("JUMP TO LATEST")
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                .tracking(1.1)
                        }
                        .foregroundStyle(Instrument.inkSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .environment(\.instrumentPressed, false)
                        .instrumentKey(RoundedRectangle(cornerRadius: 5, style: .continuous),
                                       elevation: 0.8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(InstrumentPressStyle())
                    .padding(12)
                }
            }
            .onDisappear {
                scrollRequestGeneration &+= 1
                scrollWorkScheduled = false
                scrollNeedsFollowUp = false
                scrollAnimationRequested = false
            }
        }
    }

    /// Coalesces fast token updates and gives LazyVStack time to measure the
    /// growing Markdown row before anchoring. A second pass catches delayed
    /// layout, so the user never has to press Latest to resume a live stream.
    private func requestScroll(
        _ proxy: ScrollViewProxy,
        animated: Bool = false,
        delay: TimeInterval = 0.04
    ) {
        guard followsLatest, !userIsInteracting else { return }
        scrollNeedsFollowUp = true
        scrollAnimationRequested = scrollAnimationRequested || animated
        guard !scrollWorkScheduled else { return }
        scrollWorkScheduled = true
        let generation = scrollRequestGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            while generation == scrollRequestGeneration, followsLatest, !userIsInteracting {
                scrollNeedsFollowUp = false
                let shouldAnimate = scrollAnimationRequested
                scrollAnimationRequested = false
                if shouldAnimate {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                try? await Task.sleep(for: .milliseconds(55))
                guard generation == scrollRequestGeneration,
                      followsLatest,
                      !userIsInteracting else { break }
                proxy.scrollTo("bottom", anchor: .bottom)
                if !scrollNeedsFollowUp { break }
                try? await Task.sleep(for: .milliseconds(35))
            }
            if generation == scrollRequestGeneration {
                scrollWorkScheduled = false
                scrollAnimationRequested = false
            }
        }
    }

    /// What the welcome screen's indicator actually reports. "Ready" is only
    /// true when a model is loaded — the app being open is not readiness.
    private var homeStatus: String {
        if case .failed = appState.enginePhase {
            return "Last model failed to load"
        }
        if case .loading(let name) = appState.enginePhase {
            return "Loading \(name)…"
        }
        if controller.isRunning { return "Working" }
        return appState.isModelReady ? "Ready" : "No model selected"
    }

    private var homeStatusTint: Color {
        if case .failed = appState.enginePhase { return Theme.danger }
        return Color(nsColor: .secondaryLabelColor)
    }

    /// Green only when the assistant can actually answer.
    private var homeStatusIsLive: Bool {
        appState.isModelReady || controller.isRunning
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
        // Approval responses can arrive at the same time as the live session
        // snapshot. Keep the gate's geometry stable while that state settles;
        // a disappearing action row should never make the composer jump.
        .transaction { transaction in
            transaction.animation = nil
        }
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

/// Quiet, unboxed identity drawn directly on the workspace canvas.
private struct WelcomeIdentityView: View {
    let status: String
    let statusTint: Color
    let statusIsLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            // One honest signal instead of two decorative meters: a live green
            // dot with the state written beside it. It says the app is up, and
            // it says it in words as well as colour.
            HStack(spacing: 7) {
                Circle()
                    .fill(statusIsLive ? Color.green : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 7, height: 7)
                    .overlay {
                        // The halo only breathes when the state it reports is
                        // actually live.
                        if statusIsLive {
                            Circle()
                                .stroke(Color.green.opacity(0.45), lineWidth: 3)
                                .scaleEffect(pulsing ? 2.1 : 1)
                                .opacity(pulsing ? 0 : 0.9)
                        }
                    }
                    .accessibilityHidden(true)
                Text(status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(statusTint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(status)")
            .padding(.bottom, 20)
            .task(id: statusIsLive) {
                guard statusIsLive, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }

            WelcomeEyebrow(compact: paneIsCompact, showsEyebrow: true)

            Text("Ask, browse, create, and control your Mac—with permission at every step.")
                .font(.system(size: 14))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
                .padding(.horizontal, 20)
                .padding(.top, 10)

            // Contextually relevant action, not a permanent pairing banner:
            // while the assistant cannot answer yet, the thing standing in the
            // way is a model, and that is what the hero offers. Device pairing
            // lives in the Devices destination, where it belongs.
            if statusIsLive {
                EmptyView()
            } else {
                Button {
                    NotificationCenter.default.post(name: .openModelManager, object: nil)
                } label: {
                    Label("Choose a model", systemImage: "cpu")
                }
                .glassButton(prominent: true)
                .controlSize(.large)
                .help("Pick the model that runs your next message")
                .padding(.top, 18)
            }

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @State private var width: CGFloat = 800
    private var paneIsCompact: Bool { width < 600 }
}

private struct WelcomeEyebrow: View {
    let compact: Bool
    let showsEyebrow: Bool

    var body: some View {
        if showsEyebrow {
            HStack(spacing: 8) {
                Text("What would you like to work on?")
                    // A heading is primary text. Secondary ink plus the old
                    // 38% watermark is what made this screen read as disabled.
                    .font(.appUI(size: compact ? 20 : 24, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
            }
            .accessibilityIdentifier("welcome-wordmark")
            .accessibilityAddTraits(.isHeader)
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
