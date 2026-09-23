import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Composer-local hardware materials. The deck is one machined object rather
/// than a stack of unrelated rounded controls.
private enum VampComposerChassis {
    static let top = RemoteInstrument.adaptive(0xFBF9FB, 0x333333)
    static let bottom = RemoteInstrument.adaptive(0xE8E5EA, 0x272727)
    static let recess = RemoteInstrument.adaptive(0xFFFFFF, 0x202020)
    static let recessEdge = RemoteInstrument.adaptive(0xB5AFB8, 0x0D0D0D)
    static let recessLight = RemoteInstrument.adaptive(0xFFFFFF, 0x454545)
    static let seamDark = RemoteInstrument.adaptive(0xA39DA6, 0x111111)
    static let seamLight = RemoteInstrument.adaptive(0xFFFFFF, 0x484848)
    static let insert = RemoteInstrument.adaptive(0x232226, 0x0C0C0C)

    static var face: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

private struct VampComposerSeam: View {
    let axis: Axis

    var body: some View {
        if axis == .horizontal {
            VStack(spacing: 0) {
                Rectangle().fill(VampComposerChassis.seamDark)
                Rectangle().fill(VampComposerChassis.seamLight)
            }
            .frame(height: 1.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            HStack(spacing: 0) {
                Rectangle().fill(VampComposerChassis.seamDark)
                Rectangle().fill(VampComposerChassis.seamLight)
            }
            .frame(width: 1.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct VampComposerLED: View {
    let color: Color
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var breathing = false

    private var animates: Bool { isActive && !reduceMotion && scenePhase == .active }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5.5, height: 5.5)
            .opacity(animates && breathing ? 0.58 : 1)
            .onAppear { breathing = animates }
            .onChange(of: animates) { _, active in breathing = active }
            .animation(animates ? .easeInOut(duration: 1.05).repeatForever(autoreverses: true) : nil,
                       value: breathing)
            .accessibilityHidden(true)
    }
}

private struct VampComposerBayStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? RemoteInstrument.seam.opacity(0.22) : Color.clear)
            .offset(y: configuration.isPressed && !reduceMotion ? 1 : 0)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.08 : 0.14),
                       value: configuration.isPressed)
    }
}

/// A compact restoration of Vamp's original docked instrument composer. The
/// editor grows intrinsically while the segmented control deck remains fixed.
struct RemoteComposer: View {
    @Binding var draft: String
    let isRunning: Bool
    var isReachable: Bool = true
    var isSending: Bool = false
    var hasError: Bool = false
    let onSend: () -> Void
    var onQueue: (() -> Void)? = nil
    var onSteer: (() -> Void)? = nil
    let onStop: () -> Void
    var modelName: String? = nil
    var onSelectModel: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    var modeName: String? = nil

    @State private var showTools = false
    @State private var showCommandsFallback = false
    @State private var keyboardVisible = false
    @FocusState private var focused: Bool

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var unavailable: Bool { !isReachable || isSending || (!isRunning && !hasDraft) }
    private var primaryLabel: String { isRunning ? (hasDraft ? "Queue follow-up" : "Stop the agent") : "Send" }
    private var primarySymbol: String { isRunning ? (hasDraft ? "text.badge.plus" : "stop.fill") : "arrow.up" }
    private var placeholder: String {
        if !isReachable { return "Draft while reconnecting…" }
        return isRunning ? "Queue a follow-up or steer…" : "Message Vamp…"
    }

    var body: some View {
        VStack(spacing: 0) {
            RemoteComposerEditor(draft: $draft, placeholder: placeholder, focused: $focused)
            VampComposerSeam(axis: .horizontal)
            RemoteComposerDeck(
                modelName: modelName, modeName: modeName,
                modelEnabled: onSelectModel != nil && !isRunning && isReachable,
                shareEnabled: onShare != nil && isReachable,
                primaryLabel: primaryLabel, primarySymbol: primarySymbol,
                unavailable: unavailable, isSending: isSending,
                showsSteer: isRunning && hasDraft, steerEnabled: isReachable && !isSending,
                onModel: { onSelectModel?() }, onShare: { onShare?() },
                onTools: { showTools = true }, onPrimary: primaryAction,
                onSteer: { (onSteer ?? onSend)() })
            VampComposerSeam(axis: .horizontal)
            RemoteComposerStatus(
                title: statusTitle,
                modeName: modeName,
                color: statusColor,
                isActive: isReachable && (isRunning || isSending),
                hasError: hasError)
        }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0, topTrailingRadius: 8)
                .fill(VampComposerChassis.face)
                .ignoresSafeArea(.container, edges: keyboardVisible ? [] : .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(VampComposerChassis.recessLight.opacity(0.8)).frame(height: 0.75)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: RemoteInstrument.composerWidth)
        .frame(maxWidth: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .sheet(isPresented: $showTools) {
            RemoteComposerToolsSheet { command in
                showTools = false
                choose(command)
            }
        }
        .alert("Commands", isPresented: $showCommandsFallback) {
            ForEach(RemoteComposerCommand.commands) { command in
                Button(command.title) { choose(command) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Choose a prompt to insert into your message.") }
        .onChange(of: draft) { _, value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/commands" {
                draft = ""
                showCommandsFallback = true
            }
        }
    }

    private func choose(_ command: RemoteComposerCommand) {
        draft = command.prompt
        Task { @MainActor in
            await Task.yield()
            focused = true
        }
    }

    private var statusTitle: String {
        if hasError { return "ERROR" }
        if !isReachable { return "OFFLINE" }
        if isSending { return "SENDING" }
        if isRunning { return "ACTIVE" }
        return "READY"
    }

    private var statusColor: Color {
        if hasError { return RemoteInstrument.danger }
        if !isReachable { return RemoteInstrument.secondaryInk }
        if isRunning || isSending { return RemoteInstrument.orange }
        return RemoteInstrument.green
    }

    private func primaryAction() {
        guard !unavailable else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if isRunning, hasDraft { (onQueue ?? onSend)() }
        else if isRunning { onStop() }
        else { onSend() }
    }

}

private struct RemoteComposerStatus: View {
    let title: String
    let modeName: String?
    let color: Color
    let isActive: Bool
    let hasError: Bool

    var body: some View {
        HStack(spacing: 7) {
            VampComposerLED(color: color, isActive: isActive)
            Text(title)
                .foregroundStyle(hasError ? RemoteInstrument.danger : RemoteInstrument.secondaryInk)
            if let modeName, !modeName.isEmpty {
                Text("·")
                Text(modeName.uppercased())
            }
            Spacer(minLength: 0)
            Text("VAMP / REMOTE")
                .foregroundStyle(RemoteInstrument.secondaryInk.opacity(0.72))
        }
        .font(.caption2.monospaced().weight(.semibold))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .tracking(0.5)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 20)
        .accessibilityElement(children: .combine)
    }
}

private struct RemoteComposerEditor: View {
    @Binding var draft: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var maximumLines: Int {
        if dynamicTypeSize.isAccessibilitySize { return verticalSizeClass == .compact ? 1 : 3 }
        return verticalSizeClass == .compact ? 3 : 6
    }

    var body: some View {
        TextField("", text: $draft, axis: .vertical)
            .accessibilityLabel("Message")
            .accessibilityIdentifier("remote.composer.editor")
            .font(.body)
            .lineLimit(1...maximumLines)
            .fixedSize(horizontal: false, vertical: true)
            .focused(focused)
            .foregroundStyle(RemoteInstrument.ink)
            .tint(RemoteInstrument.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            // ponytail: SwiftUI truncates a `prompt` to one line on a
            // vertical-axis field, so at accessibility sizes this read
            // "Queue a follow-u…". An overlay scales to fit instead. Held to
            // one line on purpose: the empty field is one line tall and the
            // canonical composer capture measures that geometry.
            .overlay(alignment: .leading) {
                if draft.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(RemoteInstrument.secondaryInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 12)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(VampComposerChassis.recess, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(VampComposerChassis.recessEdge, lineWidth: focused.wrappedValue ? 1 : 0.75)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(VampComposerChassis.recessLight.opacity(focused.wrappedValue ? 0.72 : 0.42))
                    .frame(height: 0.75)
                    .padding(.horizontal, 7)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(RemoteInstrument.orange)
                    .frame(width: 2, height: 21)
                    .padding(.leading, 1)
                    .opacity(focused.wrappedValue ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 6)
            .padding(.top, 7)
            .padding(.bottom, 6)
    }
}

private struct RemoteComposerDeck: View {
    let modelName: String?
    let modeName: String?
    let modelEnabled: Bool
    let shareEnabled: Bool
    let primaryLabel: String
    let primarySymbol: String
    let unavailable: Bool
    let isSending: Bool
    let showsSteer: Bool
    let steerEnabled: Bool
    let onModel: () -> Void
    let onShare: () -> Void
    let onTools: () -> Void
    let onPrimary: () -> Void
    let onSteer: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var stacksControls: Bool { dynamicTypeSize.isAccessibilitySize && verticalSizeClass != .compact }

    private var modelTitle: String {
        guard let modelName, !modelName.isEmpty else { return "Choose model" }
        if let open = modelName.lastIndex(of: "("), open > modelName.startIndex, modelName.hasSuffix(")") {
            return String(modelName[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return modelName
    }

    var body: some View {
        let layout = stacksControls
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(spacing: 0))
        layout {
            if !stacksControls {
                share.frame(width: 50)
                VampComposerSeam(axis: .vertical)
            }
            Button(action: onModel) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MODEL")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .tracking(1.25)
                            .foregroundStyle(RemoteInstrument.secondaryInk)
                        Text(modelTitle)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        .foregroundStyle(RemoteInstrument.secondaryInk)
                }
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(VampComposerBayStyle())
            .disabled(!modelEnabled)
            .accessibilityLabel("Model, \(modelName ?? "not selected")")
            .accessibilityValue(modeName ?? "")
            .accessibilityIdentifier("remote.composer.model")
            if !stacksControls { VampComposerSeam(axis: .vertical) }
            HStack(spacing: 0) {
                if stacksControls {
                    share
                    VampComposerSeam(axis: .vertical)
                }
                Button(action: onTools) {
                    Image(systemName: "circle.grid.2x2.fill")
                        .font(.system(size: 20))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(alignment: .topTrailing) {
                            Circle().fill(RemoteInstrument.orange)
                                .frame(width: 4, height: 4)
                                .padding(11)
                        }
                }
                .buttonStyle(VampComposerBayStyle())
                .frame(width: stacksControls ? nil : 52)
                .accessibilityLabel("Tools and context")
                if showsSteer {
                    VampComposerSeam(axis: .vertical)
                    Button(action: onSteer) {
                        VStack(spacing: 2) {
                            Text("STEER")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .tracking(0.9)
                            Rectangle().fill(RemoteInstrument.orange).frame(width: 13, height: 2)
                        }
                        .padding(.horizontal, 8)
                        .frame(minWidth: 58, minHeight: 48)
                    }
                    .buttonStyle(VampComposerBayStyle())
                    .disabled(!steerEnabled)
                    .accessibilityLabel("Steer")
                    .accessibilityHint("Redirects the current task instead of waiting")
                }
                VampComposerSeam(axis: .vertical)
                Button(action: onPrimary) {
                    ZStack {
                        if isSending { ProgressView().tint(.white) }
                        else { Image(systemName: primarySymbol).font(.system(size: 18, weight: .semibold)) }
                    }
                    .foregroundStyle(unavailable ? RemoteInstrument.secondaryInk : Color.white)
                    .frame(width: stacksControls ? nil : 54, height: 36)
                    .frame(maxWidth: stacksControls ? .infinity : nil, minHeight: 48)
                    .background(unavailable ? VampComposerChassis.recess : VampComposerChassis.insert,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 6)
                }
                .buttonStyle(VampComposerBayStyle())
                .disabled(unavailable)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(isSending ? "Sending" : primaryLabel)
                .accessibilityIdentifier("remote.composer.primary")
            }
            .frame(minHeight: 48)
        }
        .frame(height: stacksControls ? 96 : 48)
    }

    private var share: some View {
        Button(action: onShare) {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(VampComposerBayStyle())
        .disabled(!shareEnabled)
        .accessibilityLabel("Share clipboard or files with Mac")
    }
}

struct RemoteComposerCommand: Identifiable {
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

/// Long authorization text remains readable without pushing decisions off screen.
struct RemoteApprovalSummary: View {
    let text: String
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        ScrollView {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(RemoteInstrument.secondaryInk)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(max(contentHeight, 1), 140))
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct PendingInteractionView: View {
    let pending: RemotePendingInteraction
    var isResolving = false
    let onResolve: (String) -> Void
    @Environment(\.remoteAppearance) private var appearance
    @State private var answer = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RemoteInstrument.orange)
                    .frame(width: 28, height: 28)
                    .background(RemoteInstrument.recess, in: RoundedRectangle(cornerRadius: 6))
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

            RemoteApprovalSummary(text: pending.summary ?? pending.content ?? "Vamp Assistant needs your input.")

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
                                .buttonStyle(RemotePrimaryButtonStyle())
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                TextField("Your answer", text: $answer, prompt: Text("Your answer").foregroundStyle(RemoteInstrument.secondaryInk))
                    .padding(11)
                    .remoteRecess()
                Button("Send answer") { onResolve(answer) }
                    .buttonStyle(RemotePrimaryButtonStyle())
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 8))
                layout { actionButtons }
            }
        }
        .padding(14)
        .remoteFaceplate()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(nil, value: isResolving)
    }

    @ViewBuilder private var actionButtons: some View {
        Button(pending.kind == "plan" ? "Approve plan" : "Allow once") {
            onResolve("approve")
        }
        .buttonStyle(RemotePrimaryButtonStyle())
        .tint(BeetTheme.accent)
        .frame(maxWidth: .infinity)
        if pending.kind == "approval" {
            Button("Decline", role: .destructive) { onResolve("decline") }
                .buttonStyle(RemoteSecondaryButtonStyle())
                .frame(maxWidth: .infinity)
        }
    }

    private var title: String { switch pending.kind { case "question": "Question"; case "plan": "Plan ready"; default: "Approval needed" } }
    private var symbol: String { switch pending.kind { case "question": "questionmark.bubble"; case "plan": "list.bullet.clipboard"; default: "hand.raised.fill" } }
}

#if DEBUG
#if os(iOS)
import SwiftUI

/// Deterministic composer fixture: exercises the exact production hosting
/// path (backdrop, transcript, `safeAreaInset(edge: .bottom)`) so docking and
/// keyboard avoidance can be verified without a live Mac session.
struct RemoteComposerFixture: View {
    @State private var draft = ""
    @State private var state = "Ready"
    @State private var lastAction = "None"
    @State private var model = "Claude Sonnet · Personal workspace"
    @State private var selectedPreview = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Picker("Preview state", selection: $state) {
                            ForEach(["Ready", "Running", "Offline", "Sending"], id: \.self) { Text($0) }
                        }
                        .accessibilityIdentifier("fixture.state")
                        Spacer()
                        Text(lastAction).font(.caption).accessibilityIdentifier("fixture.lastAction")
                    }
                    RemoteTranscriptTurn(speaker: "You", text: "Make the workspace feel calmer and more precise.")
                    RemoteTranscriptTurn(speaker: "Vamp", text: "Start with the essentials.\n\n**A little more room to think.**\nThe conversation stays open, with clear typography and controls that feel deliberate.\n\nThe composer grows only when your message needs it.")
                    HStack(spacing: 8) {
                        Button {} label: {
                            Text("Press and hold").padding(.horizontal, 12).frame(minHeight: 44)
                        }.buttonStyle(RemoteKeyButtonStyle())
                        Button { selectedPreview.toggle() } label: {
                            Text("Selected").padding(.horizontal, 12).frame(minHeight: 44)
                        }.buttonStyle(RemoteKeyButtonStyle(isSelected: selectedPreview))
                            .accessibilityAddTraits(selectedPreview ? .isSelected : [])
                    }
                    .frame(minHeight: 44)
                    .font(.subheadline)
                    if state == "Running" {
                        RemoteTranscriptTurn(speaker: "Vamp", text: "Reviewing the layout and controls…", phase: "Working")
                    }
                }
                .padding(16)
            }
            .background(RemoteInstrument.reading)
            .navigationTitle("A quieter workspace")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissToolbar()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RemoteComposer(draft: $draft, isRunning: state == "Running",
                    isReachable: state != "Offline", isSending: state == "Sending",
                    onSend: { lastAction = "Send"; draft = "" },
                    onQueue: { lastAction = "Queue"; draft = "" },
                    onSteer: { lastAction = "Steer"; draft = "" },
                    onStop: { lastAction = "Stop"; state = "Ready" },
                    modelName: model, onSelectModel: { model = "GPT-5 Codex" },
                    onShare: { lastAction = "Share" }, modeName: "Code")
            }
        }
        .onAppear {
            let env = ProcessInfo.processInfo.environment
            switch env["VAMP_REMOTE_FIXTURE"] {
            case "running": state = "Running"
            case "offline": state = "Offline"
            case "sending": state = "Sending"
            case "multiline": draft = "One\nTwo\nThree\nFour\nFive\nSix\nSeven\nEight"
            default: break
            }
        }
    }
}
#endif

/// Local visual fixture; no network requests or session mutations.
struct RemoteComposerDesignPreview: View {
    var body: some View { RemoteComposerFixture() }
}

#Preview("Silver composer") {
    RemoteComposerFixture().environment(\.remoteAppearance, .light).preferredColorScheme(.light)
}
#Preview("Graphite composer") {
    RemoteComposerFixture().environment(\.remoteAppearance, .dark).preferredColorScheme(.dark)
}

#endif

struct RemoteComposerToolsSheet: View {
    let onChoose: (RemoteComposerCommand) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RemoteInstrumentForm {
                toolSection("Workspace", commands: Array(RemoteComposerCommand.commands.prefix(2)))
                toolSection("Browser", commands: Array(RemoteComposerCommand.commands.dropFirst(2).prefix(3)))
                toolSection("System", commands: Array(RemoteComposerCommand.commands.suffix(1)))
                Section {
                    Text("Choosing a command inserts a prompt into your draft. Review it before sending.")
                        .font(.footnote).foregroundStyle(RemoteInstrument.secondaryInk)
                }
            }
            .navigationTitle("Tools & context")
            .navigationBarTitleDisplayMode(.inline)
            .remoteNavigationChrome()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }.vampUtilityAction() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    private func toolSection(_ title: String, commands: [RemoteComposerCommand]) -> some View {
        Section(title) {
            ForEach(commands) { command in
                Button { onChoose(command) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: command.symbol)
                            .font(.subheadline)
                            .frame(width: 32, height: 32)
                            .background(RemoteInstrument.recess, in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(command.title).font(.subheadline.weight(.semibold))
                            Text(command.detail).font(.footnote).foregroundStyle(RemoteInstrument.secondaryInk)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(RemoteInstrument.secondaryInk)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(RemotePressButtonStyle())
            }
        }
    }

}
