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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    ForEach(detail.messages) { message in
                        MessageBubble(
                            message: message,
                            onRevert: message.checkpointID == nil ? nil : onRevertCheckpoint)
                    }
                    if detail.isRunning { StreamingBubble(text: detail.streamingText, phase: detail.phase) }
                    if let error = detail.error, error.message != dismissedErrorMessage {
                        RemoteChatErrorCard(error: error, onDismiss: onDismissError)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: RemoteInstrument.contentWidth)
                .padding(.horizontal, 16).padding(.vertical, 16).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(BeetTheme.readingSurface(appearance))
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.top, for: .alignment)
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
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
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
            requestScroll(proxy, animated: !reduceMotion, delay: 0)
        } label: {
            Label(detail.isRunning ? "Jump to latest" : "Latest", systemImage: "arrow.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(RemoteInstrument.pearl, in: Capsule())
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        if message.role == "user" {
            RemoteTranscriptTurn(speaker: "You", text: message.content)
        }
        else if message.role == "toolCall" || message.role == "toolResult" { ToolMessageCard(message: message) }
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
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                    .textSelection(.enabled)
                Spacer(minLength: 4)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.red.opacity(0.3), lineWidth: 0.75) }
        }
        else if message.role == "notice" {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BeetTheme.accentBright)
                Text(message.content)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                Spacer(minLength: 4)
            }
        }
        else {
            RemoteTranscriptTurn(speaker: "Vamp", text: message.content)
        }
    }
}

/// Shared geometry prevents the answer moving when a stream becomes a message.
struct RemoteTranscriptTurn: View {
    let speaker: String
    let text: String
    var phase: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(speaker).font(.caption.weight(.semibold))
                if let phase {
                    ProgressView().controlSize(.mini)
                    Text(phase.capitalized).font(.caption)
                }
            }
            .foregroundStyle(RemoteInstrument.secondaryInk)
            if text.isEmpty, phase != nil {
                Text("Vamp is working…").font(.body).foregroundStyle(RemoteInstrument.secondaryInk)
            } else { MarkdownText(text) }
        }
        .foregroundStyle(RemoteInstrument.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The model's visible working, collapsed by default. It is deliberately
/// quieter than an answer bubble: smaller type, no avatar, muted colour.
struct ReasoningMessageCard: View {
    let message: RemoteMessage
    @Environment(\.remoteAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : RemoteInstrument.motion) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain").font(.caption)
                    VampMicroLabel(title: "Reasoning")
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }
                .foregroundStyle(RemoteInstrument.secondaryInk)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(RemotePressButtonStyle())
            .accessibilityLabel(expanded ? "Hide reasoning" : "Show reasoning")
            if expanded {
                VampHairline()
                Text(LocalizedStringKey(message.content))
                    .font(.footnote)
                    .lineSpacing(3)
                    .foregroundStyle(RemoteInstrument.secondaryInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(expanded ? RemoteInstrument.recess : .clear, in: RoundedRectangle(cornerRadius: 8))
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
                    .font(.system(.caption2, design: .monospaced, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                Text(message.content)
                    .font(.caption)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if onRevert != nil {
                Button("Revert") { confirming = true }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(RemoteSecondaryButtonStyle())
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BeetTheme.surfaceStrong(appearance),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    .foregroundStyle(BeetTheme.accentBright)
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
                .foregroundStyle(BeetTheme.secondaryText(appearance))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BeetTheme.surfaceStrong(appearance), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(BeetTheme.line(appearance), lineWidth: 0.75)
        }
    }
}

struct MarkdownText: View {
    let content: String
    init(_ content: String) { self.content = content }

    private struct Block {
        var text: String
        var heading = 0
        var isCode = false
    }

    // Parse only presentation boundaries; preserve incomplete streamed code fences.
    private var blocks: [Block] {
        var result: [Block] = []
        var lines: [String] = []
        var code = false
        func flush() {
            if !lines.isEmpty {
                result.append(Block(text: lines.joined(separator: "\n"), isCode: code))
                lines.removeAll(keepingCapacity: true)
            }
        }
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                flush()
                code.toggle()
            } else if code {
                lines.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                let level = line.prefix(while: { $0 == "#" }).count
                if (1...6).contains(level), line.dropFirst(level).first == " " {
                    flush()
                    result.append(Block(text: String(line.dropFirst(level + 1)), heading: level))
                } else {
                    lines.append(line)
                }
            }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.isCode {
                    ScrollView(.horizontal) {
                        Text(block.text).font(.callout.monospaced())
                            .textSelection(.enabled).padding(12)
                    }
                    .remoteRecess()
                } else {
                    Text((try? AttributedString(markdown: block.text,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text))
                        .font(block.heading == 0 ? .body : .headline)
                        .lineSpacing(block.heading == 0 ? 5 : 2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(block.heading == 0 ? [] : .isHeader)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolMessageCard: View {
    let message: RemoteMessage
    @Environment(\.remoteAppearance) private var appearance
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if !displayContent.isEmpty {
                Text(displayContent).font(.callout.monospaced()).lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RemoteInstrument.recess, in: RoundedRectangle(cornerRadius: 8))
            }
        } label: {
            Label(displayName, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(message.didFail ? RemoteInstrument.danger : RemoteInstrument.secondaryInk)
                .frame(minHeight: 44)
        }
        .tint(RemoteInstrument.secondaryInk)
    }

    /// A failed tool used to render with the same checkmark as a successful
    /// one — the Mac tracked the failure but it never crossed the wire.
    private var symbol: String {
        if message.role == "toolCall" { return "hammer" }
        return message.didFail ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var displayName: String {
        let raw = message.toolName ?? "Tool activity"
        return raw.replacingOccurrences(of: "dynamic:", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }

    private var displayContent: String {
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "{}" { return "" }
        guard let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !array.isEmpty else { return message.content }
        let text = array.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.isEmpty ? message.content : text
    }
}

struct StreamingBubble: View {
    let text: String, phase: String
    var body: some View {
        RemoteTranscriptTurn(speaker: "Vamp", text: text, phase: phase)
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
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(BeetTheme.accentBright)
                        Text(item.message)
                            .font(.caption)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button {
                        onCancel(item.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                            .hitTarget(8)
                    }
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                    .buttonStyle(RemotePressButtonStyle())
                    .accessibilityLabel("Remove queued follow-up")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(BeetTheme.line(appearance).opacity(0.9), lineWidth: 0.75)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: RemoteInstrument.contentWidth)
        .frame(maxWidth: .infinity)
    }
}
