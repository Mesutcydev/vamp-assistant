import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RemoteComposer: View {
    @Binding var draft: String
    let isRunning: Bool
    var isReachable: Bool = true
    var isSending: Bool = false
    let onSend: () -> Void
    var onQueue: (() -> Void)? = nil
    var onSteer: (() -> Void)? = nil
    let onStop: () -> Void
    @Environment(\.remoteAppearance) private var appearance
    @FocusState private var isComposerFocused: Bool
    @State private var showCommands = false

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            Button { showCommands = true } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 40, height: 44)
                    .hitTarget(2)
            }
            .foregroundStyle(BeetTheme.accentBright)
            .buttonStyle(RemotePressButtonStyle())
            .accessibilityLabel("Commands and context")
            TextField(placeholder, text: $draft, axis: .vertical)
                .font(.body).lineLimit(1...6).padding(.vertical, 12)
                .focused($isComposerFocused)
            if isComposerFocused {
                Button {
                    isComposerFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .buttonStyle(RemotePressButtonStyle())
                .accessibilityLabel("Hide keyboard")
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
            if isRunning, hasDraft {
                Button {
                    if let onSteer { onSteer() } else { onSend() }
                } label: {
                    Text("Steer")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(BeetTheme.accentBright)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(BeetTheme.surfaceStrong(appearance), in: Capsule())
                }
                .buttonStyle(RemotePressButtonStyle())
                .disabled(!isReachable || isSending)
                .accessibilityLabel("Steer this turn")
                .accessibilityHint("Redirects the current task instead of waiting")
            }
            Button(action: primaryAction) {
                Image(systemName: primarySymbol)
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(primaryColor, in: Circle())
            }
            .disabled(!isReachable || isSending || (!isRunning && !hasDraft))
            .buttonStyle(RemotePressButtonStyle())
            .accessibilityLabel(primaryLabel)
            .padding(.trailing, 4).padding(.vertical, 4)
        }
        .animation(.easeOut(duration: 0.16), value: isComposerFocused)
        .animation(.easeOut(duration: 0.16), value: isRunning && hasDraft)
        .frame(maxWidth: 720)
        .remoteGlass(appearance, radius: 21, strong: true)
        .shadow(color: .black.opacity(appearance == .light ? 0.10 : 0.22), radius: 18, y: 8)
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
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

    private var primarySymbol: String {
        if isRunning, hasDraft { return "text.badge.plus" }
        if isRunning { return "stop.fill" }
        return "arrow.up"
    }

    private var primaryColor: Color {
        if isRunning, hasDraft { return BeetTheme.accent }
        if isRunning { return BeetTheme.accent }
        return BeetTheme.accent
    }

    private var primaryLabel: String {
        if isRunning, hasDraft { return "Queue follow-up" }
        if isRunning { return "Stop the agent" }
        return "Send"
    }

    private func primaryAction() {
        if isRunning, hasDraft {
            if let onQueue { onQueue() } else { onSend() }
        } else if isRunning {
            onStop()
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
    @Environment(\.remoteAppearance) private var appearance

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
            .background(BeetTheme.background(appearance))
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BeetTheme.accentBright)
                        .frame(width: 34, height: 34)
                        .background(BeetTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(command.title).font(.subheadline.weight(.semibold))
                        Text(command.detail).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

struct PendingInteractionView: View {
    let pending: RemotePendingInteraction
    var isResolving = false
    let onResolve: (String) -> Void
    @Environment(\.remoteAppearance) private var appearance
    @State private var answer = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BeetTheme.accentBright)
                    .frame(width: 34, height: 34)
                    .background(BeetTheme.accent.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let toolName = pending.toolName, !toolName.isEmpty {
                        Text(toolName).font(.caption.monospaced())
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                    }
                }
                Spacer()
                Text(pending.kind == "approval" ? "REVIEW" : "INPUT")
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(BeetTheme.accentBright)
            }

            Text(pending.summary ?? pending.content ?? "Vamp Assistant needs your input.")
                .font(.subheadline)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
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
                        .tint(BeetTheme.accentBright)
                    Text("Continuing…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
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
                    .padding(11)
                    .background(BeetTheme.surfaceStrong(appearance), in: RoundedRectangle(cornerRadius: 11))
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
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(appearance == .light ? 0.08 : 0.2), radius: 14, y: 6)
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
