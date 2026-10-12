import AppKit
import SwiftUI

// MARK: - Instrument frame
//
// The window is a device with an even 46pt frame: left rail, top tab strip,
// right control column, and the bottom key bar all share one thickness. The
// middle is the chat — the writing well belongs to the middle, while every
// button lives on the frame, each under its own sliding cap.

enum ChatFrameMetrics {
    /// Every frame bar is the same thickness as the navigation rail, so the
    /// window reads as one device with an even bezel.
    static let columnWidth: CGFloat = InstrumentScale.bar
    static let barHeight: CGFloat = InstrumentScale.bar
    /// The writing well in the middle of the device.
    static let inputMinHeight: CGFloat = 72
    /// Below this content width the key row is split into two rows: the
    /// single row needs ~455–535 pt, and the minimum window leaves ~400 pt.
    static let keyRowCompactWidth: CGFloat = 620
}

// MARK: - Middle: the writing well

/// The middle of the device: one large recessed well for the draft. No keys
/// live in here — the caret and the text are the only things inside, and the
/// well grows with real content.
struct ChatInputWell: View {
    @Environment(\.workspaceWindowID) private var workspaceWindowID
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AgentSessionController
    @ObservedObject private var settings = SettingsStore.shared
    var store: ComposerStore

    @State private var showsTurnContext = false
    @FocusState private var editorFocused: Bool
    /// Whether the resident engine can see image bytes itself (a GGUF model
    /// launched with a staged mmproj). Drives the attachment lane's label so
    /// the user knows if a picture will be seen or only described.
    @State private var engineSeesImages = false
    /// Measured content width of the composer; drives the key-row layout.
    @State private var availableWidth: CGFloat = 800

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.attachments.isEmpty { attachmentLane }
            editor
            keyRow
            composerNoteRow
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: ChatFrameMetrics.inputMinHeight, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(editorFocused ? Theme.accent : Theme.hairline,
                                                           lineWidth: editorFocused ? 1.5 : 1)
        }
        .contentShape(Rectangle())
        .defaultFocus($editorFocused, true)
        // Ask the resident engine once per attachment change whether images
        // reach it as pixels (projector loaded) or as a sidecar description.
        .task(id: store.attachments.map(\.id)) {
            guard store.attachments.contains(where: { $0.isImage }) else {
                engineSeesImages = false
                return
            }
            engineSeesImages = await appState.engine.supportsImageInput
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message composer")
    }

    /// One supporting row under the editor: what you are sending WITH on the
    /// leading side (attachments, model, mode), and the single primary action
    /// on the trailing side. Narrow widths fold the secondary menus into one
    /// native menu rather than wrapping into a second row — send and the
    /// current model never leave the surface.
    private var keyRow: some View {
        let populated = !store.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                sourceMarks
                ModelSelectionPill(maxLabelWidth: compactRow ? 85 : 160, plainStyle: true)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                projectIcon
                toolsIcon
                if !compactRow && !controller.isRunning { modeTextKey }
                if !controller.isRunning || !populated { sendKey }
            }
            if controller.isRunning && populated {
                HStack(spacing: 8) {
                    Text("Working").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    Menu {
                        Button("Steer current work") { _ = store.steer() }.disabled(!store.canSteer)
                    } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).frame(width: 24).accessibilityLabel("Follow-up options")
                    Button("Queue follow-up") { _ = store.queue() }
                        .buttonStyle(.borderedProminent).disabled(!store.canQueue)
                        .accessibilityIdentifier("queue-follow-up")
                    sendKey
                }
            }
        }
    }

    /// Below this the menus collapse; the editor still needs its full width.
    private var compactRow: Bool {
        availableWidth < ChatFrameMetrics.keyRowCompactWidth
    }

    /// The tool and project menus, folded into one native menu when the
    /// composer is narrow.
    private var supportingMenu: some View {
        Menu {
            Button("Tools…", systemImage: "wrench.and.screwdriver") {
                NotificationCenter.default.postWorkspace(name: .openAppSettings, object: nil, windowID: workspaceWindowID)
            }
            Button("Open project…", systemImage: "folder") {
                NotificationCenter.default.postWorkspace(name: .openWorkspace, object: nil, windowID: workspaceWindowID)
            }
            Button("Review changed files", systemImage: "doc.text.magnifyingglass") {
                NotificationCenter.default.postWorkspace(name: .gitDiff, object: nil, windowID: workspaceWindowID)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .frame(width: 24)
        .help("More composer actions")
    }

    /// Attachments: what the message carries, so it leads the row.
    private var sourceMarks: some View {
        sourceIcon("paperclip", help: "Attach files") { attachFiles() }
    }

    private var editor: some View {
        TextField("", text: Binding(get: { store.prompt }, set: { store.prompt = $0 }),
                  prompt: Text("What's on your mind?")
                      .foregroundStyle(Theme.placeholderOnSilver),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .fixedSize(horizontal: false, vertical: true)
            .font(.appUI(size: 15))
            .foregroundStyle(Instrument.ink)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityLabel("Task description")
            .focused($editorFocused)
            .onKeyPress(phases: .down) { press in
                if press.key == .escape && controller.isRunning {
                    controller.stop()
                    return .handled
                }
                if press.key == .return,
                   let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    if editor.hasMarkedText() { return .ignored }
                    if press.modifiers == .shift || press.modifiers == .option
                        || (press.modifiers.isEmpty && !settings.enterSends) {
                        editor.insertNewlineIgnoringFieldEditor(nil)
                        return .handled
                    }
                }
                if ShortcutBinding(rawValue: settings.sendShortcut).matches(press) {
                    _ = store.submit()
                    return .handled
                }
                if press.key == .return && press.modifiers.contains(.command) {
                    _ = store.submit()
                    return .handled
                }
                if press.key == .return && press.modifiers.isEmpty && settings.enterSends {
                    _ = store.submit()
                    return .handled
                }
                return .ignored
            }
    }

    /// The composer's honest status line. `ComposerStore` already computed why a
    /// send is blocked and whether a follow-up can be queued, but no view read
    /// either value: a dimmed Send explained nothing and a queued follow-up was
    /// indistinguishable from a dropped one.
    @ViewBuilder
    private var composerNoteRow: some View {
        if let note = composerNote {
            Text(note)
                .font(.appUI(size: 11))
                .foregroundStyle(composerNoteIsFault ? Theme.warning : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Composer status: \(note)")
        }
    }

    private var composerNote: String? {
        if controller.isRunning {
            if let blocked = store.runningActionBlocker { return blocked }
            let queued = appState.queuedTasks
                .filter { $0.sessionID == controller.activeSessionID }
                .count
            guard queued > 0 else { return nil }
            return queued == 1
                ? "1 follow-up queued — it runs when this turn finishes"
                : "\(queued) follow-ups queued — they run when this turn finishes"
        }
        guard let blocker = store.sendBlocker else { return nil }
        // "Describe the task first" is simply the resting state of an empty
        // composer, so it gets no caption; a missing or still-loading model is
        // exactly what the user needs to hear.
        if blocker == "Describe the task first" { return nil }
        // The model pill on this same row already reads "Choose Model" when
        // nothing is selected, and the empty-state hero offers the same action.
        // Repeating it here as an orange warning made three competing versions
        // of one message on the home screen.
        if blocker == "Choose a model to run", !appState.isModelReady { return nil }
        return blocker
    }

    private var composerNoteIsFault: Bool {
        !controller.isRunning && store.sendBlocker != nil
    }

    /// Attachments occupy their own lane above the draft, never over it.
    private var attachmentLane: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.attachments) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: attachment.isImage ? "photo" : "doc.text")
                            .font(.system(size: 9, weight: .medium))
                        Text(attachment.name)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                        if attachment.isImage {
                            // Say what will actually happen to the picture:
                            // "vision" = the model sees the bytes, "described"
                            // = a sidecar or BYOK model summarises it first.
                            Text(engineSeesImages ? "vision" : "described")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(engineSeesImages
                                                 ? Theme.positive
                                                 : Theme.textSecondary)
                                .accessibilityLabel(engineSeesImages
                                    ? "This model sees the image directly"
                                    : "This model receives a text description of the image")
                        }
                        Button {
                            store.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .foregroundStyle(Instrument.engraved)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.black.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Instrument.seam.opacity(0.5), lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 24)
    }

    /// Frameless glyph control: the source and voice actions are plain marks
    /// on the page, not keys — no face, no frame, only the icon.
    private func sourceIcon(_ systemName: String, help: String,
                            disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: InstrumentScale.markGlyph, weight: .medium))
                .foregroundStyle(disabled
                                 ? Instrument.engraved.opacity(0.45)
                                 : Instrument.inkSecondary)
                .frame(width: InstrumentScale.mark, height: InstrumentScale.mark)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarMarkPressStyle())
        .disabled(disabled)
        .lfHoverLift()
        .help(help)
        .accessibilityLabel(help)
    }

    /// Tools menu as a page mark: the same options the top bar used to hold.
    private var toolsIcon: some View {
        Menu {
            Button("Browser", systemImage: "globe") { NotificationCenter.default.postWorkspace(name: .openWorkspacePanel, object: WorkspacePanel.browser, windowID: workspaceWindowID) }
            Button("Specialist activity", systemImage: "list.bullet.rectangle") {
                NotificationCenter.default.postWorkspace(name: .openWorkspacePanel, object: WorkspacePanel.activity, windowID: workspaceWindowID)
            }
            Divider()
            Toggle("Mac control", isOn: $settings.computerControlEnabled)
            Toggle("Plan before working", isOn: $settings.planMode)
            Button("Roles & context…") { showsTurnContext = true }
            ForEach(AgentMode.allCases) { mode in
                Button { settings.agentMode = mode } label: {
                    Label(mode.label, systemImage: settings.agentMode == mode ? "checkmark" : mode.icon)
                }
            }
        } label: { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 32) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .help("Task options").accessibilityLabel("Task options")
        .popover(isPresented: $showsTurnContext) { IntentPicker(store: store).background(Theme.surface) }
    }

    private var projectIcon: some View {
        Menu {
            Button("Open project…", systemImage: "folder") { NotificationCenter.default.postWorkspace(name: .openWorkspace, object: nil, windowID: workspaceWindowID) }
            if controller.workspaceURL != nil {
                Button("Review changes", systemImage: "doc.text.magnifyingglass") {
                    NotificationCenter.default.postWorkspace(name: .openWorkspacePanel, object: WorkspacePanel.changes, windowID: workspaceWindowID)
                }
                Button("Project context", systemImage: "square.stack.3d.up") {
                    NotificationCenter.default.postWorkspace(name: .openWorkspacePanel, object: WorkspacePanel.context, windowID: workspaceWindowID)
                }
            }
        } label: {
            Image(systemName: controller.workspaceURL == nil ? "folder.badge.plus" : "folder")
                .frame(width: 28, height: 32)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .help(controller.workspaceURL?.path ?? "Add project context")
        .accessibilityLabel("Project: \(controller.workspaceURL?.lastPathComponent ?? "None")")
    }

    private var modeTextKey: some View {
        Text(settings.agentMode.label)
            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            .help("Change the assistant mode in Task options")
    }

    /// The page's primary action: send while idle, stop while running. It
    /// belongs beside the draft, not on the frame.
    /// The one primary action, in the system's own prominent button style —
    /// AppKit draws its fill, focus ring, and disabled state.
    private var sendKey: some View {
        Button {
            if controller.isRunning { controller.stop() } else { _ = store.submit() }
        } label: {
            Image(systemName: controller.isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 24)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        // No `.defaultAction`: Return belongs to the editor, which honours the
        // user's send-key preference and never dispatches on marked text.
        .disabled(!controller.isRunning && !store.canSend)
        .help(controller.isRunning ? "Stop (Esc)" : "Send")
        .accessibilityLabel(controller.isRunning ? "Stop" : "Send")
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        store.addAttachments(panel.urls)
    }

    /// Commit the draft after a short quiet period. The editor remains fully
    /// responsive while a paste or fast typing burst arrives; validation and
    /// persistence catch up once the value settles.

}
