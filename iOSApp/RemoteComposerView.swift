import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The input bar: one field, one primary action.
///
/// It used to hold up to four conditional buttons — a hide-keyboard glyph, a
/// Steer capsule, and a primary circle that meant Send, Queue or Stop depending
/// on state without ever saying which. Stop now belongs to the run bar, and the
/// keyboard dismisses on scroll, so what is left is a field and a send button.
struct RemoteComposer: View {
    @Binding var draft: String
    let isRunning: Bool
    var isReachable: Bool = true
    var isSending: Bool = false
    let onSend: () -> Void
    var onQueue: (() -> Void)? = nil
    var onSteer: (() -> Void)? = nil
    @Environment(\.remoteAppearance) private var appearance
    @FocusState private var isComposerFocused: Bool
    @State private var showCommands = false

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                showCommands = true
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(RemoteSurface.well(appearance), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 3)
            .accessibilityLabel("Commands and context")

            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...6)
                    .padding(.vertical, 8)
                    .focused($isComposerFocused)

                if isRunning, hasDraft {
                    // The alternative to the default, so it is bordered rather
                    // than filled: Send queues for after this turn, Steer
                    // redirects the turn now.
                    Button("Steer") { (onSteer ?? onSend)() }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .disabled(!isReachable || isSending)
                        .padding(.bottom, 3)
                        .accessibilityHint("Redirects the current task instead of waiting")
                }

                Button(action: primaryAction) {
                    Image(systemName: isRunning ? "text.badge.plus" : "arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(BeetTheme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isReachable || isSending || !hasDraft)
                .opacity(hasDraft && isReachable && !isSending ? 1 : 0.35)
                .padding(.bottom, 4)
                .accessibilityLabel(isRunning ? "Queue follow-up" : "Send")
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .background(
                Capsule()
                    .fill(RemoteSurface.well(appearance)))
            .overlay(Capsule().stroke(RemoteSurface.separator(appearance), lineWidth: 0.5))
        }
        .sheet(isPresented: $showCommands) {
            RemoteCommandPopover(draft: $draft) {
                showCommands = false
                isComposerFocused = true
            }
            .presentationDetents([.height(392)])
            .presentationDragIndicator(.visible)
            .presentationBackground(RemoteSurface.card(appearance))
        }
        .animation(.easeOut(duration: 0.16), value: isRunning && hasDraft)
        .frame(maxWidth: 720)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(RemoteSurface.card(appearance))
        .onChange(of: draft) { _, value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/commands" {
                draft = ""
                showCommands = true
            }
        }
    }

    private var placeholder: String {
        if !isReachable { return "Draft a message while reconnecting…" }
        if isRunning { return "Queue a follow-up or steer…" }
        return "Message your assistant…"
    }

    private func primaryAction() {
        if isRunning {
            if let onQueue { onQueue() } else { onSend() }
        } else {
            submit()
        }
    }

    private func submit() {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/commands" {
            draft = ""
            showCommands = true
        } else {
            onSend()
        }
    }
}

private struct RemoteComposerCommand: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let prompt: String

    static let commands: [RemoteComposerCommand] = [
        .init(id: "diff", title: "Git diff", detail: "Review uncommitted changes", symbol: "arrow.left.arrow.right",
              prompt: "Inspect the current git diff. Summarize the changes, flag concrete bugs or regressions, and suggest the smallest useful test plan. Do not edit files unless I ask."),
        .init(id: "context", title: "@context", detail: "Use the current workspace and chat", symbol: "paperclip",
              prompt: "@context Use the current workspace, active session, recent messages, and available tool state as context for this request: "),
        .init(id: "browser-open", title: "Open page", detail: "Navigate with browser control", symbol: "safari",
              prompt: "Use browser control to open this URL: "),
        .init(id: "browser-read", title: "Read page", detail: "Inspect the current browser page", symbol: "doc.text.magnifyingglass",
              prompt: "Use browser control to inspect the current page. Summarize its visible content and important interactive elements."),
        .init(id: "browser-shot", title: "Browser screenshot", detail: "Capture and analyze the page", symbol: "camera.viewfinder",
              prompt: "Use browser control to take a screenshot of the current page and analyze what is visible."),
        .init(id: "status", title: "System status", detail: "Check Mac and Tailscale", symbol: "waveform.path.ecg",
              prompt: "Check the Mac and Tailscale status using the dedicated read-only status tools. Report the result without navigating system UI."),
    ]
}

/// The composer's shortcuts, as a panel hung off the `+`.
///
/// This was a half-height sheet with a navigation bar and a grouped list — a
/// whole screen borrowed for six one-line shortcuts, whose first section the
/// detent cut off. A popover is the right size for the content and keeps the
/// conversation visible behind it.
private struct RemoteCommandPopover: View {
    @Binding var draft: String
    let onChoose: () -> Void
    @Environment(\.remoteAppearance) private var appearance

    private var groups: [(String, [RemoteComposerCommand])] {
        [("Workspace", Array(RemoteComposerCommand.commands.prefix(2))),
         ("Browser control", Array(RemoteComposerCommand.commands.dropFirst(2).prefix(3))),
         ("Device", Array(RemoteComposerCommand.commands.suffix(1)))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                Text(group.0.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.primary.opacity(0.5))
                    .padding(.horizontal, 14)
                    .padding(.top, index == 0 ? 12 : 14)
                    .padding(.bottom, 4)
                ForEach(group.1) { command in
                    row(command)
                    if command.id != group.1.last?.id {
                        Rectangle()
                            .fill(RemoteSurface.separator(appearance))
                            .frame(height: 0.75)
                            .padding(.leading, 48)
                    }
                }
            }
        }
        .padding(.bottom, 10)
        .frame(width: 292)
    }

    private func row(_ command: RemoteComposerCommand) -> some View {
        Button {
            draft = command.prompt
            onChoose()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: command.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.7))
                    .frame(width: 26, height: 26)
                    .background(RemoteSurface.well(appearance),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(command.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(command.title), \(command.detail)")
    }
}

/// What the model asks for before it acts, drawn the way ChatGPT draws it:
/// one panel with a title, the request itself, and the answer as full-width
/// buttons at the bottom — the primary filled, the refusal plain.
///
/// It used to be a grey card with a coloured glyph and a row of bordered
/// buttons that wrapped to two lines on a small phone; the buttons were the
/// same size as the tool chips above them, so the one moment the run is
/// waiting on you looked like every other row.
struct PendingInteractionView: View {
    let pending: RemotePendingInteraction
    var isResolving = false
    let onResolve: (String) -> Void
    @Environment(\.remoteAppearance) private var appearance
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if let toolName = pending.toolName, !toolName.isEmpty {
                        Text(toolName)
                            .font(.caption.monospaced())
                            .foregroundStyle(RemoteInk.quiet)
                            .lineLimit(1)
                    }
                }

                if let items = planItems {
                    RemoteTaskListView(title: "Plan", items: items)
                } else {
                    Text(bodyText)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.78))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let preview = pending.preview {
                    RemoteApprovalPreviewView(preview: preview)
                }
            }
            .padding(14)

            Rectangle()
                .fill(RemoteSurface.separator(appearance))
                .frame(height: 0.75)

            answerArea
                .padding(12)
        }
        // Outlined, not filled. Every other surface on the page lets the
        // ground through now, and a filled panel here was the one card left
        // in the transcript — it read as a notification dropped on top of the
        // conversation rather than a turn inside it.
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(RemoteSurface.separator(appearance), lineWidth: 0.75)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(nil, value: isResolving)
    }

    private var canAnswer: Bool {
        !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bodyText: String {
        pending.summary ?? pending.content ?? "Vamp Assistant needs your input."
    }

    /// A plan is a list of steps; drawn as a paragraph you approve a wall of
    /// text. Only claims the text is a plan when it really parses as one.
    private var planItems: [RemoteTaskItem]? {
        guard pending.kind == "plan" else { return nil }
        return RemoteTaskListParser.parse(pending.content ?? pending.summary ?? "")
    }

    @ViewBuilder private var answerArea: some View {
        if isResolving {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Continuing…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .accessibilityLabel("Continuing")
        } else if pending.kind == "question" {
            VStack(spacing: 8) {
                if let options = pending.options, !options.isEmpty {
                    ForEach(options, id: \.self) { option in
                        Button {
                            onResolve(option)
                        } label: {
                            HStack(spacing: 10) {
                                Text(option)
                                    .font(.subheadline.weight(.medium))
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.left")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(RemoteInk.quiet)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .frame(maxWidth: .infinity)
                            .background(RemoteSurface.well(appearance),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 8) {
                    TextField(pending.options?.isEmpty == false ? "Something else…" : "Your answer",
                              text: $answer)
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(RemoteSurface.well(appearance),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button {
                        onResolve(answer)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(canAnswer ? AnyShapeStyle(BeetTheme.accent)
                                                  : AnyShapeStyle(RemoteSurface.well(appearance)),
                                        in: Circle())
                            .foregroundStyle(canAnswer ? AnyShapeStyle(Color.white)
                                                       : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAnswer)
                    .accessibilityLabel("Send answer")
                }
            }
        } else {
            VStack(spacing: 8) { actionButtons }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        Button(pending.kind == "plan" ? "Approve plan" : "Allow once") {
            onResolve("approve")
        }
        .buttonStyle(RemoteAnswerButtonStyle(kind: .primary, appearance: appearance))
        if pending.kind == "approval" {
            Button("Not now") { onResolve("decline") }
                .buttonStyle(RemoteAnswerButtonStyle(kind: .secondary, appearance: appearance))
        }
    }

    private var title: String { switch pending.kind { case "question": "Question"; case "plan": "Plan ready"; default: "Approval needed" } }
    private var symbol: String { switch pending.kind { case "question": "questionmark.bubble"; case "plan": "list.bullet.clipboard"; default: "hand.raised.fill" } }
}


/// The two answers to a pending request: filled and plain, both full width and
/// both 44pt, so which one is the default is never in doubt.
struct RemoteAnswerButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    @Environment(\.isEnabled) private var isEnabled
    let kind: Kind
    let appearance: RemoteAppearance

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 16)
            .background(background(configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(foreground)
            .opacity(isEnabled ? 1 : 0.5)
    }

    private func background(_ pressed: Bool) -> AnyShapeStyle {
        switch kind {
        case .primary:
            isEnabled ? AnyShapeStyle(BeetTheme.accent.opacity(pressed ? 0.82 : 1))
                      : AnyShapeStyle(RemoteSurface.well(appearance))
        case .secondary:
            AnyShapeStyle(RemoteSurface.well(appearance).opacity(pressed ? 0.6 : 1))
        }
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .primary:
            isEnabled ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
        case .secondary:
            AnyShapeStyle(HierarchicalShapeStyle.primary)
        }
    }
}
