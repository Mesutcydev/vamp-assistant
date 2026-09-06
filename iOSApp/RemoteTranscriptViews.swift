import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MessageTranscript: View {
    let detail: RemoteSessionDetail
    var dismissedErrorMessage: String? = nil
    var onDismissError: (() -> Void)? = nil
    /// Nil while the agent is running — the Mac refuses an undo mid-run, so the
    /// button should not be offered rather than offered and rejected.
    var onRevertCheckpoint: (() -> Void)? = nil
    @Environment(\.remoteAppearance) private var appearance
    /// Whether the transcript should keep the newest response in view. This is
    /// deliberately separate from the scroll geometry: content height grows
    /// while a response streams, and treating that growth as user scrolling
    /// makes the “Latest” affordance appear even when the user never touched
    /// the transcript.
    @State private var followsLatest = true
    @State private var userIsInteracting = false
    @State private var scrollRequestGeneration = 0
    @State private var scrollWorkScheduled = false
    @State private var scrollNeedsFollowUp = false
    @State private var scrollAnimationRequested = false

    private struct ScrollMetrics: Equatable {
        let offsetY: CGFloat
        let bottomDistance: CGFloat
    }

    private static let followThreshold: CGFloat = 64

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 24) {
                    ForEach(TranscriptItem.build(from: detail.messages)) { item in
                        switch item.kind {
                        case .message(let message):
                            MessageBubble(
                                message: message,
                                onRevert: message.checkpointID == nil ? nil : onRevertCheckpoint)
                        case .tools(let entries):
                            ToolLedger(entries: entries)
                        }
                    }
                    if detail.isRunning { StreamingBubble(text: detail.streamingText, phase: detail.phase) }
                    if let error = detail.error, error.message != dismissedErrorMessage {
                        RemoteChatErrorCard(error: error, onDismiss: onDismissError)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 16).padding(.vertical, 22).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            // Geometry is sampled independently from the scroll phase. The
            // phase tells us whether a change could have come from a finger;
            // without that distinction, every streamed token looks like the
            // user scrolled away from the bottom.
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offsetY: geometry.contentOffset.y,
                    bottomDistance: max(0, geometry.contentSize.height - geometry.visibleRect.maxY))
            } action: { previous, atBottom in
                guard userIsInteracting else { return }
                if atBottom.bottomDistance <= Self.followThreshold {
                    if !followsLatest { followsLatest = true }
                } else if atBottom.offsetY < previous.offsetY - 1 {
                    // Only a real upward drag disables follow. Content height
                    // changes during streaming leave the offset untouched.
                    if followsLatest { followsLatest = false }
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
            .onAppear { requestScroll(proxy) }
            // Unanimated: a spring restarted per token was also the jitter.
            .onChange(of: detail.streamingText) { _, _ in
                guard followsLatest else { return }
                requestScroll(proxy)
            }
            .onChange(of: detail.messages.count) { _, _ in
                guard followsLatest else { return }
                requestScroll(proxy, animated: true)
            }
            .onChange(of: detail.isRunning) { _, _ in
                guard followsLatest else { return }
                requestScroll(proxy, animated: true)
            }
            .onChange(of: detail.id) { _, _ in
                // A reused navigation cell can keep @State from the previous
                // session. A newly opened conversation should always begin at
                // its newest message.
                scrollRequestGeneration &+= 1
                scrollWorkScheduled = false
                scrollNeedsFollowUp = false
                scrollAnimationRequested = false
                followsLatest = true
                userIsInteracting = false
                requestScroll(proxy)
            }
            .overlay(alignment: .bottom) {
                if !followsLatest { jumpToLatest(proxy) }
            }
            .onDisappear {
                scrollRequestGeneration &+= 1
                scrollWorkScheduled = false
                scrollNeedsFollowUp = false
                scrollAnimationRequested = false
            }
        }
    }

    /// Coalesce token-driven scroll requests and wait for the lazy stack to
    /// finish laying out the new text. Calling `scrollTo` in the same update
    /// that changes a token can target the previous content height, which is
    /// the source of the old “press Latest” behavior.
    private func requestScroll(
        _ proxy: ScrollViewProxy,
        animated: Bool = false,
        delay: TimeInterval = 0.04
    ) {
        // Do not compete with a finger or trackpad drag. If the user keeps
        // following the latest message, the next streamed delta will request
        // the anchor again after the interaction has ended.
        guard followsLatest, !userIsInteracting else { return }
        // A trailing debounce alone never fires when model deltas arrive
        // faster than the debounce interval: every token cancels the previous
        // request. Keep one small main-actor worker alive instead. It drains
        // follow-up requests at a steady cadence and performs a second pass
        // after layout, so the bottom anchor tracks both fast local models and
        // slower network streams without animation jitter.
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
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                // Lazy stacks may publish their final height one run-loop
                // turn after the first scroll. Re-anchoring once prevents the
                // user from having to press Latest after a long response.
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

    private func jumpToLatest(_ proxy: ScrollViewProxy) -> some View {
        Button {
            followsLatest = true
            userIsInteracting = false
            requestScroll(proxy, animated: true, delay: 0)
        } label: {
            Label(detail.isRunning ? "Jump to latest" : "Latest", systemImage: "arrow.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().stroke(BeetTheme.line(appearance), lineWidth: 0.75) }
                .contentShape(Capsule())
        }
        .buttonStyle(RemotePressButtonStyle())
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
        .accessibilityLabel("Jump to latest message")
    }
}

struct MessageBubble: View {
    let message: RemoteMessage
    /// Only supplied where a revert is actually possible (an open session that
    /// is not running); nil elsewhere, and the checkpoint row hides the button.
    var onRevert: (() -> Void)? = nil
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        // The prompt sits in a container and the answer does not — that
        // contrast is the speaker cue, the way Cursor and Codex do it. A
        // right-aligned bubble reads as a text message, which an agent run
        // is not.
        if message.role == "user" {
            MarkdownText(message.content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RemoteSurface.card(appearance),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("You: \(message.content)")
        }
        // Tool steps never reach here: the transcript groups them into a
        // ledger before drawing. Kept out of the bubble switch so there is one
        // place that decides how a step looks.
        else if message.role == "toolCall" || message.role == "toolResult" {
            ToolLedger(entries: ToolLedgerBuilder.entries(from: [message]))
        }
        // Reasoning is the model's working, not its answer. It used to fall
        // through to the assistant bubble below, which presented thinking as
        // conclusions.
        else if message.role == "reasoning" { ReasoningMessageCard(message: message) }
        else if message.role == "checkpoint" { CheckpointMessageRow(message: message, onRevert: onRevert) }
        // Errors used to render as EmptyView(), so scrolling back through a
        // session showed no trace of anything that had gone wrong.
        else if message.role == "error" {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(message.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        else if message.role == "notice" {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BeetTheme.accentBright)
                Text(message.content)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
        }
        else {
            MarkdownText(message.content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Vamp Assistant: \(message.content)")
        }
    }
}

/// The model's working, collapsed by default and quieter than an answer:
/// a disclosure line, and the text itself behind a hairline rule.
struct ReasoningMessageCard: View {
    let message: RemoteMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Thinking")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide thinking" : "Show thinking")

            if expanded {
                Text(message.content)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 2)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A git checkpoint the agent took before mutating the tree. Carries the revert
/// affordance, which the phone could not offer while checkpoints arrived as
/// stringified notices.
struct CheckpointMessageRow: View {
    let message: RemoteMessage
    var onRevert: (() -> Void)? = nil
    @Environment(\.remoteAppearance) private var appearance
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BeetTheme.accentBright)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Checkpoint")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(message.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if onRevert != nil {
                Button("Revert") { confirming = true }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RemoteSurface.card(appearance),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .confirmationDialog("Restore this checkpoint?",
                            isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) { onRevert?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Mac's working tree is rolled back to this point. Changes made after it are lost.")
        }
    }
}

struct RemoteChatErrorCard: View {
    let error: RemoteErrorPresentation
    var onDismiss: (() -> Void)? = nil
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Label(error.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Spacer(minLength: 8)
                if let onDismiss {
                    Button("Dismiss", action: onDismiss)
                        .font(.caption.weight(.semibold))
                }
            }
            Text(error.message)
                .font(.subheadline)
                .lineSpacing(3)
                .textSelection(.enabled)
            Text("You can change the model or start a new chat. This failed chat will not be reopened automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RemoteSurface.card(appearance),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct MarkdownText: View {
    let content: String
    init(_ content: String) { self.content = content }
    var body: some View { if let value = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { Text(value).font(.body).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } else { Text(content).font(.body).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
}

/// The steps of a run, as one ledger.
///
/// Each tool used to be its own filled, rounded card — and a call and its
/// result were two of them, so a single web search printed two identical
/// boxes stacked on top of each other. Boxes are also the wrong weight: these
/// are the run's margin notes, not its content. Consecutive steps now merge
/// into one block against a left rule, a call folding into its own result,
/// with the output behind a disclosure.
struct ToolLedger: View {
    let entries: [ToolLedgerEntry]
    @Environment(\.remoteAppearance) private var appearance
    @State private var expandedIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                row(entry)
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(RemoteSurface.separator(appearance))
                .frame(width: 1.5)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func row(_ entry: ToolLedgerEntry) -> some View {
        let isExpanded = expandedIDs.contains(entry.id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !entry.output.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    if isExpanded { expandedIDs.remove(entry.id) } else { expandedIDs.insert(entry.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    status(entry)
                    Text(entry.name)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.primary.opacity(0.78))
                        .lineLimit(1)
                    if !entry.summary.isEmpty, !isExpanded {
                        Text(entry.summary)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    if !entry.output.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.state.spokenWord) \(entry.name)")
            .accessibilityHint(entry.output.isEmpty ? "" : (isExpanded ? "Hide output" : "Show output"))

            if isExpanded, !entry.output.isEmpty {
                Text(entry.output)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .lineLimit(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func status(_ entry: ToolLedgerEntry) -> some View {
        switch entry.state {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
        case .done:
            // A green filled disc turned every step into a notification badge.
            // Done is the quiet state; only a failure earns colour.
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
        }
    }
}

struct ToolLedgerEntry: Identifiable, Equatable {
    enum State: Equatable {
        case running, done, failed

        var spokenWord: String {
            switch self {
            case .running: "Running"
            case .done: "Finished"
            case .failed: "Failed"
            }
        }
    }

    let id: String
    let name: String
    var state: State
    var output: String

    /// The first line of the output, shown beside the name while collapsed —
    /// the difference between "web search" and "web search · 5 results".
    var summary: String {
        guard state != .running else { return "" }
        let line = output.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }
}

/// Turns a transcript into what the ledger draws: consecutive tool messages
/// grouped, and a call folded into the result that answers it.
enum ToolLedgerBuilder {
    static func entries(from messages: [RemoteMessage]) -> [ToolLedgerEntry] {
        var out: [ToolLedgerEntry] = []
        for message in messages {
            let name = displayName(message)
            let output = displayOutput(message)
            if message.role == "toolCall" {
                out.append(ToolLedgerEntry(id: message.id, name: name,
                                           state: .running, output: output))
                continue
            }
            let state: ToolLedgerEntry.State = message.didFail ? .failed : .done
            // The result answers the most recent unfinished call of the same
            // name; without that, one search rendered as two rows.
            if let index = out.lastIndex(where: { $0.name == name && $0.state == .running }) {
                out[index].state = state
                if !output.isEmpty { out[index].output = output }
            } else {
                out.append(ToolLedgerEntry(id: message.id, name: name,
                                           state: state, output: output))
            }
        }
        return out
    }

    static func displayName(_ message: RemoteMessage) -> String {
        let raw = message.toolName ?? "Tool activity"
        return raw.replacingOccurrences(of: "dynamic:", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }

    static func displayOutput(_ message: RemoteMessage) -> String {
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "{}" || trimmed.isEmpty { return "" }
        guard let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !array.isEmpty else { return message.content }
        let text = array.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.isEmpty ? message.content : text
    }
}

struct StreamingBubble: View {
    let text: String, phase: String
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        // No phase line here any more: the run bar above the composer says
        // what is happening, and said it twice before.
        VStack(alignment: .leading, spacing: 8) {
            if text.isEmpty {
                Text("Working…").foregroundStyle(BeetTheme.secondaryText(appearance))
            } else {
                MarkdownText(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QueuedFollowUpsView: View {
    let items: [RemoteQueuedItem]
    let onCancel: (UUID) -> Void
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(spacing: 6) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(BeetTheme.accentBright)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label ?? "Queued")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(BeetTheme.accentBright)
                        Text(item.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button {
                        onCancel(item.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                    }
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove queued follow-up")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RemoteSurface.card(appearance),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }
}


/// A transcript as it is drawn: ordinary messages, and runs of tool steps
/// collapsed into a single ledger so a search does not occupy two cards and
/// 48 points of air.
struct TranscriptItem: Identifiable {
    enum Kind {
        case message(RemoteMessage)
        case tools([ToolLedgerEntry])
    }

    let id: String
    let kind: Kind

    static func build(from messages: [RemoteMessage]) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        var pending: [RemoteMessage] = []

        func flush() {
            guard !pending.isEmpty else { return }
            let entries = ToolLedgerBuilder.entries(from: pending)
            if let first = pending.first {
                out.append(TranscriptItem(id: "tools-\(first.id)", kind: .tools(entries)))
            }
            pending = []
        }

        for message in messages {
            if message.role == "toolCall" || message.role == "toolResult" {
                pending.append(message)
            } else {
                flush()
                out.append(TranscriptItem(id: message.id, kind: .message(message)))
            }
        }
        flush()
        return out
    }
}
