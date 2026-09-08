import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Composer-local materials. The chassis is a machined part docked into the
/// bottom of the page canvas; tonal steps and seams carry the hierarchy, not
/// shadows. Light values sit cooler than the warm page canvas; dark values
/// follow the graphite instrument family so the deck reads as the same object
/// in another lighting condition.
private enum VampChassis {
    // Neutral machine grays. The dark family is deliberately cast-free (equal
    // R/G/B) so the deck reads as the mac's charcoal instrument, not a
    // green-ish tint. Light values stay slightly cool against the warm page.
    static let top = RemoteInstrument.adaptive(0xDFDEDC, 0x313131)
    static let bottom = RemoteInstrument.adaptive(0xD2D1CE, 0x2A2A2A)
    // The dark recess is a machined plate, not a deep socket: one subtle step
    // below the chassis (so the editor reads as set into the deck) but well
    // above the near-black insert. The border is a hairline engraving, not a
    // heavy ring, so the plate and chassis read as one component.
    static let recess = RemoteInstrument.adaptive(0xC7C6C3, 0x2A2A2A)
    static let recessEdge = RemoteInstrument.adaptive(0xA9A8A5, 0x1C1C1C)
    static let recessLight = RemoteInstrument.adaptive(0xF5F4F1, 0x3E3E3E)
    static let key = RemoteInstrument.adaptive(0xE8E7E4, 0x363636)
    static let insert = RemoteInstrument.adaptive(0x2B2B2A, 0x121212)
    static let edge = RemoteInstrument.adaptive(0xF8F7F4, 0x4A4A4A)
    static let seamDark = RemoteInstrument.adaptive(0x9C9B99, 0x151515)
    static let seamLight = RemoteInstrument.adaptive(0xF4F3F0, 0x4A4A4A)

    static var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

/// A machined channel between adjacent parts: one dark edge plus one light
/// edge, so a boundary reads as depth instead of a table divider.
private struct VampChassisSeam: View {
    var axis: Axis

    var body: some View {
        Group {
            if axis == .horizontal {
                VStack(spacing: 0) {
                    Rectangle().fill(VampChassis.seamDark)
                    Rectangle().fill(VampChassis.seamLight)
                }
                .frame(height: 2)
            } else {
                HStack(spacing: 0) {
                    Rectangle().fill(VampChassis.seamDark)
                    Rectangle().fill(VampChassis.seamLight)
                }
                .frame(width: 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Status LED: a live breathe only while the machine is actually working.
private struct VampComposerLED: View {
    let color: Color
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var breathing = false

    private var breathes: Bool { isActive && !reduceMotion && scenePhase == .active }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5.5, height: 5.5)
            .opacity(breathes ? (breathing ? 1 : 0.65) : 1)
            .onAppear { breathing = isActive }
            .onChange(of: isActive) { _, active in breathing = active }
            .animation(breathes ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : nil,
                       value: breathing)
            .accessibilityHidden(true)
    }
}

/// Bay press: quick settle down, slightly slower return. Reads as a key.
private struct VampBayPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.982 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(configuration.isPressed ? .easeIn(duration: 0.1) : .easeOut(duration: 0.15),
                       value: configuration.isPressed)
    }
}

/// The bottom control deck of the Vamp machine: one docked chassis holding a
/// recessed editor, a bayed control row, and an integrated status strip.
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

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isComposerFocused: Bool
    @State private var showTools = false
    @State private var showCommandsFallback = false
    @State private var keyboardVisible = false

    private var isCompact: Bool { verticalSizeClass == .compact }
    private var isAccessibility: Bool { dynamicTypeSize.isAccessibilitySize }
    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Instrument proportions. The chassis extends through the bottom safe
    // area; the band below the status strip is chassis material, not a gap.
    private var chassisRadius: CGFloat { 9 }
    private var editorHeight: CGFloat { isCompact ? 50 : 74 }
    private var deckHeight: CGFloat { isCompact ? 52 : 56 }
    private var statusHeight: CGFloat { isCompact ? 20 : 22 }

    var body: some View {
        chassis
            .buttonStyle(VampBayPressStyle())
            .foregroundStyle(RemoteInstrument.ink)
            // The chassis is one full-width instrument. The material bleeds
            // through the bottom safe area so the deck reaches the physical
            // screen edge; only the material extends, the controls stay above
            // the home indicator. When the keyboard is up it already covers
            // that region, so the bleed is suppressed to keep the deck flush
            // against the keyboard instead of painting behind it.
            .background(alignment: .bottom) {
                Group {
                    if keyboardVisible {
                        dockShape.fill(VampChassis.gradient)
                    } else {
                        dockShape.fill(VampChassis.gradient).ignoresSafeArea(edges: .bottom)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                Group {
                    if keyboardVisible {
                        dockShape.strokeBorder(VampChassis.edge, lineWidth: 0.75)
                    } else {
                        dockShape.strokeBorder(VampChassis.edge, lineWidth: 0.75)
                            .ignoresSafeArea(edges: .bottom)
                    }
                }
                .allowsHitTesting(false)
            }
            .padding(.top, 9)
            .frame(maxWidth: RemoteInstrument.composerWidth)
            .frame(maxWidth: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardVisible = false
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isComposerFocused)
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
            } message: {
                Text("Choose a prompt to insert into your message.")
            }
            .onChange(of: draft) { _, value in
                if value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/commands" {
                    draft = ""
                    showCommandsFallback = true
                }
            }
    }

    @ViewBuilder private var chassis: some View {
        if isAccessibility {
            accessibilityStack
        } else {
            standardStack
        }
    }

    private var dockShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: chassisRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: chassisRadius,
            style: .continuous)
    }

    private var standardStack: some View {
        VStack(spacing: 0) {
            editorRecess
            VampChassisSeam(axis: .horizontal)
            controlDeck
            VampChassisSeam(axis: .horizontal)
            statusStrip
        }
    }

    private var accessibilityStack: some View {
        VStack(spacing: 0) {
            editorRecess
            VampChassisSeam(axis: .horizontal)
            modelBay.frame(minHeight: 52)
            VampChassisSeam(axis: .horizontal)
            HStack(spacing: 0) {
                shareBay
                VampChassisSeam(axis: .vertical)
                toolsBay
                VampChassisSeam(axis: .vertical)
                Group {
                    if isComposerFocused { keyboardBay } else { modeBay }
                }
            }
            .frame(height: 52)
            VampChassisSeam(axis: .horizontal)
            terminalBay(fullWidth: true)
            VampChassisSeam(axis: .horizontal)
            statusStrip
        }
    }

    private var editorRecess: some View {
        TextField(placeholder, text: $draft,
                  prompt: Text(isAccessibility ? "Message…" : placeholder)
                      .foregroundStyle(RemoteInstrument.secondaryInk),
                  axis: .vertical)
            .accessibilityLabel(placeholder)
            .font(.body)
            .lineLimit(1...(isCompact ? 3 : 8))
            .foregroundStyle(RemoteInstrument.ink)
            .tint(RemoteInstrument.ink)
            .focused($isComposerFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: editorHeight, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(VampChassis.recess)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(VampChassis.recessEdge, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(VampChassis.recessLight, lineWidth: 0.75)
                    .offset(y: 0.75)
                    .opacity(0.55)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(RemoteInstrument.orange)
                    .frame(width: 2, height: 22)
                    .padding(.leading, 2)
                    .opacity(isComposerFocused ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isComposerFocused)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 6)
    }

    private var controlDeck: some View {
        HStack(spacing: 0) {
            shareBay.frame(width: 52)
            VampChassisSeam(axis: .vertical)
            modelBay
            VampChassisSeam(axis: .vertical)
            toolsBay.frame(width: 56)
            VampChassisSeam(axis: .vertical)
            Group {
                if isComposerFocused { keyboardBay } else { modeBay }
            }
            .frame(width: 80)
            VampChassisSeam(axis: .vertical)
            terminalBay().frame(width: 60)
        }
        .frame(height: deckHeight)
    }

    private var shareBay: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onShare?()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(RemoteInstrument.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .disabled(onShare == nil || !isReachable)
        .accessibilityLabel("Share clipboard or files with Mac")
    }

    private var toolsBay: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showTools = true
        } label: {
            Image(systemName: "circle.grid.2x2.fill")
                .font(.system(size: 22))
                .foregroundStyle(RemoteInstrument.ink)
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(RemoteInstrument.orange)
                        .frame(width: 4.5, height: 4.5)
                        .offset(x: 2, y: -1)
                        .opacity(0.9)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Tools and context")
    }

    private var keyboardBay: some View {
        Button {
            isComposerFocused = false
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(RemoteInstrument.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Hide keyboard")
    }

    private var modelBay: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSelectModel?()
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MODEL")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(RemoteInstrument.secondaryInk)
                    Text(modelShortName)
                        .font(isAccessibility ? .body.weight(.medium) : .system(size: 15, weight: .medium))
                        .lineLimit(isAccessibility ? 2 : 1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.82)
                        .foregroundStyle(RemoteInstrument.ink)
                }
                Spacer(minLength: 6)
                if onSelectModel != nil {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RemoteInstrument.secondaryInk)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(onSelectModel == nil || isRunning || !isReachable)
        .accessibilityLabel("Model, \(modelName ?? "not selected")")
        .accessibilityHint(isRunning ? "Model cannot change during a turn" : "Opens the searchable model list")
    }

    /// A compact, readable label for the bay. The server sends a provider tag
    /// in a trailing parenthetical (e.g. "Muse Spark 1.3…(opencode Go)"). That
    /// tag is what forces the ugly mid-string "…(…)…" collapse in a one-line
    /// bay, so the bay shows the model core and lets the picker surface the
    /// provider. Falls back to tail truncation instead of a mid-string cut.
    private var modelShortName: String {
        guard let modelName, !modelName.isEmpty else { return "Choose model" }
        // Drop a trailing "(provider)" tag when present, preserving the core.
        if let open = modelName.lastIndex(of: "("),
           open > modelName.startIndex,
           modelName.hasSuffix(")") {
            return String(modelName[modelName.startIndex..<open])
                .trimmingCharacters(in: .whitespaces)
        }
        return modelName
    }

    private var modeBay: some View {
        Group {
            if let modeName {
                Text(modeName.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(VampChassis.insert, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(RemoteInstrument.orange)
                            .frame(width: 12, height: 2)
                            .padding(.bottom, 3)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("Session mode, \(modeName)")
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func terminalBay(fullWidth: Bool = false) -> some View {
        Button(action: primaryAction) {
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(primaryUnavailable ? VampChassis.key : VampChassis.insert)
                Image(systemName: primarySymbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(primaryUnavailable ? RemoteInstrument.secondaryInk : Color.white)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: primarySymbol)
            }
            .overlay(alignment: .topTrailing) {
                if isRunning, !hasDraft, !primaryUnavailable {
                    Circle()
                        .fill(RemoteInstrument.orange)
                        .frame(width: 4, height: 4)
                        .padding(4)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: fullWidth ? .infinity : 48,
                   minHeight: fullWidth ? 48 : deckHeight - 12,
                   maxHeight: fullWidth ? 48 : nil,
                   alignment: .center)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .disabled(primaryUnavailable)
        .accessibilityLabel(primaryLabel)
    }

    private var statusStrip: some View {
        HStack(spacing: 7) {
            VampComposerLED(color: statusColor, isActive: statusAnimated)
            Text(statusTitle)
                .foregroundStyle(hasError ? RemoteInstrument.danger : RemoteInstrument.secondaryInk)
            if let modeName, !isAccessibility {
                Text("·")
                Text(modeName.uppercased())
            }
            Spacer(minLength: 8)
            if isRunning, hasDraft {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if let onSteer { onSteer() } else { onSend() }
                } label: {
                    Text("STEER")
                        .tracking(1)
                        .foregroundStyle(RemoteInstrument.orange)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                }
                .disabled(!isReachable || isSending)
                .accessibilityHint("Redirects the current task instead of waiting")
            }
        }
        .font(.caption2.monospaced().weight(.semibold))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: statusHeight)
        .foregroundStyle(RemoteInstrument.secondaryInk)
    }

    private var primaryUnavailable: Bool {
        !isReachable || isSending || (!isRunning && !hasDraft)
    }

    private var primarySymbol: String {
        if isRunning, hasDraft { return "text.badge.plus" }
        if isRunning { return "stop.fill" }
        return "arrow.up"
    }

    private var primaryLabel: String {
        if isRunning, hasDraft { return "Queue follow-up" }
        if isRunning { return "Stop the agent" }
        return "Send"
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

    private var statusAnimated: Bool {
        isReachable && (isRunning || isSending)
    }

    private func choose(_ command: RemoteComposerCommand) {
        draft = command.prompt
        Task { @MainActor in
            await Task.yield()
            isComposerFocused = true
        }
    }

    private var placeholder: String {
        if !isReachable { return "Draft while reconnecting…" }
        if isRunning { return "Queue a follow-up or steer…" }
        return "What’s on your mind?"
    }

    private func primaryAction() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            showCommandsFallback = true
        } else {
            onSend()
        }
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
    @Environment(\.remoteAppearance) private var appearance
    @State private var draft = ""
    @State private var running = false
    @State private var reachable = true
    @State private var model = "Muse Spark 1.3…(opencode Go)"
    @State private var mode = "Code"

    private var fixtureEnum: String? {
        ProcessInfo.processInfo.environment["VAMP_REMOTE_FIXTURE"]
    }

    var body: some View {
        ZStack {
            RemoteBackdrop()
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(running ? RemoteInstrument.orange : RemoteInstrument.green)
                        .frame(width: 6, height: 6)
                    Text(running ? "ACTIVE · CODE" : "READY · CODE")
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(RemoteInstrument.secondaryInk)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<8, id: \.self) { i in
                            Text(i.isMultiple(of: 2)
                                 ? "Docked chassis fixture line \(i + 1). The composer must sit flush above the keyboard."
                                 : "Transcript sample. Verify the gap between the last message and the deck.")
                                .font(.body)
                                .foregroundStyle(RemoteInstrument.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Toggle("Running", isOn: $running)
                    Toggle("Reachable", isOn: $reachable)
                }
                .font(.caption2.monospaced())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RemoteInstrument.panel, in: RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 40)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RemoteComposer(
                draft: $draft,
                isRunning: running,
                isReachable: reachable,
                onSend: { draft = "" },
                onQueue: { draft = "" },
                onSteer: { draft = "" },
                onStop: { running = false },
                modelName: model,
                onSelectModel: { model = "GPT-5 Codex" },
                modeName: mode)
        }
        .environment(\.remoteAppearance, appearance)
        .onAppear {
            if fixtureEnum == "focused" {
                draft = "Keyboard open alignment check…"
            } else if fixtureEnum == "running" {
                running = true
                draft = "Queued a follow-up while the agent works…"
            } else if fixtureEnum == "offline" {
                reachable = false
            }
        }
    }
}
#endif

/// Local visual fixture; no network requests or session mutations.
struct RemoteComposerDesignPreview: View {
    @State private var draft = ""
    @State private var running = false

    var body: some View {
        ZStack {
            RemoteBackdrop()
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "building.columns.fill").font(.largeTitle)
                Text("VAMP ASSISTANT")
                    .font(.title.weight(.semibold)).fontDesign(.default)
                Text("Your Mac. In your pocket.")
                    .font(.subheadline).foregroundStyle(RemoteInstrument.secondaryInk)
                Spacer()
                Toggle("Preview running task", isOn: $running)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 24)
                RemoteComposer(draft: $draft, isRunning: running,
                               onSend: { draft = "" }, onQueue: { draft = "" },
                               onSteer: { draft = "" }, onStop: { running = false })
            }
        }
        .environment(\.remoteAppearance, .dark)
        .preferredColorScheme(.dark)
    }
}

#Preview("Instrument composer") {
    RemoteComposerDesignPreview()
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
