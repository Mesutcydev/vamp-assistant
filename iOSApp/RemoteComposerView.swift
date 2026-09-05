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
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
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
                    .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.7)))
            .overlay(Capsule().stroke(Color(uiColor: .separator), lineWidth: 0.5))
        }
        .animation(.easeOut(duration: 0.16), value: isRunning && hasDraft)
        .frame(maxWidth: 720)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .sheet(isPresented: $showCommands) {
            RemoteCommandPalette(draft: $draft) {
                showCommands = false
                isComposerFocused = true
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
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

private struct RemoteCommandPalette: View {
    @Binding var draft: String
    let onChoose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Workspace") {
                    commandRows(Array(RemoteComposerCommand.commands.prefix(2)))
                }
                Section("Browser control") {
                    commandRows(Array(RemoteComposerCommand.commands.dropFirst(2).prefix(3)))
                }
                Section("Device") {
                    commandRows(Array(RemoteComposerCommand.commands.suffix(1)))
                }
            }
            .scrollContentBackground(.hidden)
            .background { RemoteBackdrop() }
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private func commandRows(_ commands: [RemoteComposerCommand]) -> some View {
        ForEach(commands) { command in
            Button {
                draft = command.prompt
                onChoose()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: command.symbol)
                        .font(.body)
                        .foregroundStyle(BeetTheme.accentBright)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(command.title).foregroundStyle(.primary)
                        Text(command.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .remoteListRow()
        }
    }
}

struct PendingInteractionView: View {
    let pending: RemotePendingInteraction
    var isResolving = false
    let onResolve: (String) -> Void
    @State private var answer = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BeetTheme.accentBright)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let toolName = pending.toolName, !toolName.isEmpty {
                        Text(toolName).font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Text(pending.summary ?? pending.content ?? "Vamp Assistant needs your input.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .textSelection(.enabled)

            // The change itself, not a description of it.
            if let preview = pending.preview {
                RemoteApprovalPreviewView(preview: preview)
            }

            if isResolving {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Continuing…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityLabel("Continuing")
            } else if pending.kind == "question" {
                if let options = pending.options, !options.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(options, id: \.self) { option in
                            Button(option) { onResolve(option) }
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                TextField("Your answer", text: $answer)
                    .textFieldStyle(.roundedBorder)
                Button("Send answer") { onResolve(answer) }
                    .buttonStyle(.borderedProminent)
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                ViewThatFits {
                    HStack(spacing: 9) { actionButtons }
                    VStack(spacing: 9) { actionButtons }
                }
            }
        }
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground).opacity(0.92),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(nil, value: isResolving)
    }

    @ViewBuilder private var actionButtons: some View {
        Button(pending.kind == "plan" ? "Approve plan" : "Allow once") {
            onResolve("approve")
        }
        .buttonStyle(.borderedProminent)
        .tint(BeetTheme.accent)
        .frame(maxWidth: .infinity)
        if pending.kind == "approval" {
            Button("Decline", role: .destructive) { onResolve("decline") }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
    }

    private var title: String { switch pending.kind { case "question": "Question"; case "plan": "Plan ready"; default: "Approval needed" } }
    private var symbol: String { switch pending.kind { case "question": "questionmark.bubble"; case "plan": "list.bullet.clipboard"; default: "hand.raised.fill" } }
}
