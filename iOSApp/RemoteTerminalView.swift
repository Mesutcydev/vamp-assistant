import SwiftTerm
import SwiftUI
import UIKit

@MainActor
final class RemoteTerminalChatStore: ObservableObject {
    enum Role: Equatable {
        case system
        case command
        case output
        case error
    }

    struct Block: Identifiable, Equatable {
        let id: UUID
        let role: Role
        var text: String
        var isStreaming: Bool
    }

    @Published private(set) var blocks: [Block] = []
    private var inputBuffer = Data()
    private var lastOutputID: UInt64 = 0
    private var activeOutputID: UUID?
    private let maxBlocks = 160
    private let maxCharacters = 14_000

    func reset() {
        blocks = [Block(id: UUID(), role: .system, text: "Opening shell…", isStreaming: true)]
        inputBuffer.removeAll(keepingCapacity: true)
        lastOutputID = 0
        activeOutputID = nil
    }

    func ingest(_ chunks: [RemoteTerminalSession.OutputChunk]) {
        for chunk in chunks where chunk.id > lastOutputID {
            lastOutputID = chunk.id
            appendOutput(chunk.data)
        }
    }

    func update(state: RemoteTerminalSession.State) {
        switch state {
        case .open:
            finishOpening()
            if !blocks.contains(where: { $0.role == .system && $0.text == "Terminal is connected." }) {
                append(Block(id: UUID(), role: .system, text: "Terminal is connected.", isStreaming: false))
            }
        case .closed(let reason):
            finishOpening()
            append(Block(id: UUID(), role: .error, text: reason.map { "Terminal closed · \($0)" } ?? "Terminal closed.", isStreaming: false))
        case .failed(let message):
            appendFailure(message)
        case .idle, .opening:
            break
        }
    }

    func recordInput(_ data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0D || byte == 0x0A {
                submitCommand(String(decoding: inputBuffer, as: UTF8.self))
                inputBuffer.removeAll(keepingCapacity: true)
            } else if byte == 0x08 || byte == 0x7F {
                var value = String(decoding: inputBuffer, as: UTF8.self)
                if !value.isEmpty { value.removeLast() }
                inputBuffer = Data(value.utf8)
            } else if byte == 0x1B {
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) {
                    index += 1
                }
            } else if byte >= 0x20 {
                inputBuffer.append(byte)
            }
            index += 1
        }
    }

    func submitCommand(_ command: String) {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        finishOpening()
        append(Block(id: UUID(), role: .command, text: "$ \(value)", isStreaming: false))
        activeOutputID = nil
    }

    func appendFailure(_ message: String) {
        finishOpening()
        append(Block(id: UUID(), role: .error, text: message, isStreaming: false))
    }

    var latestText: String {
        blocks.suffix(20).map(\.text).joined(separator: "\n")
    }

    private func appendOutput(_ data: Data) {
        let clean = Self.clean(data)
        guard !clean.isEmpty else { return }
        for line in clean.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if let activeOutputID,
               let index = blocks.firstIndex(where: { $0.id == activeOutputID }),
               blocks[index].text.count + value.count < maxCharacters {
                blocks[index].text += "\n\(value)"
                blocks[index].isStreaming = true
            } else {
                let block = Block(id: UUID(), role: .output, text: value, isStreaming: true)
                activeOutputID = block.id
                append(block)
            }
        }
    }

    private func finishOpening() {
        for index in blocks.indices where blocks[index].role == .system && blocks[index].isStreaming {
            blocks[index].isStreaming = false
        }
    }

    private func append(_ block: Block) {
        blocks.append(block)
        if blocks.count > maxBlocks {
            blocks.removeFirst(blocks.count - maxBlocks)
        }
    }

    private static func clean(_ data: Data) -> String {
        let scalars = String(decoding: data, as: UTF8.self).unicodeScalars
        var result = String.UnicodeScalarView()
        var index = scalars.startIndex
        var skippingCSI = false
        var skippingOSC = false
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if skippingOSC {
                if scalar.value == 7 { skippingOSC = false }
                index = scalars.index(after: index)
                continue
            }
            if skippingCSI {
                if (0x40...0x7E).contains(scalar.value) { skippingCSI = false }
                index = scalars.index(after: index)
                continue
            }
            if scalar.value == 0x1B {
                let next = scalars.index(after: index)
                if next < scalars.endIndex {
                    if scalars[next].value == 0x5B {
                        skippingCSI = true
                        index = scalars.index(after: next)
                        continue
                    }
                    if scalars[next].value == 0x5D {
                        skippingOSC = true
                        index = scalars.index(after: next)
                        continue
                    }
                }
                index = next
                continue
            }
            if scalar.value == 0x08 || scalar.value == 0x7F {
                index = scalars.index(after: index)
                continue
            }
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D || scalar.value >= 0x20 {
                result.append(scalar)
            }
            index = scalars.index(after: index)
        }
        return String(result)
    }
}

private enum RemoteTerminalPresentation: String, CaseIterable, Identifiable {
    case stream
    case raw

    var id: String { rawValue }
    var title: String { self == .stream ? "Task chat" : "Raw terminal" }
    var icon: String { self == .stream ? "bubble.left.and.bubble.right" : "terminal" }
}

/// Vamp Control–matching Terminal Mode: SwiftTerm always mounted, Task chat
/// composer + special keys chrome, capsule presentation switch.
struct RemoteTerminalView: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var session: RemoteTerminalSession
    @StateObject private var chat = RemoteTerminalChatStore()
    @StateObject private var input = RemoteTerminalInputController()
    @State private var presentation: RemoteTerminalPresentation = .stream
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(store: RemoteStore) {
        self.store = store
        _session = StateObject(wrappedValue: RemoteTerminalSession(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            presentationBar
            ZStack {
                // Keep SwiftTerm mounted while switching modes so PTY scrollback
                // never closes/reopens (Vamp TerminalModeView pattern).
                SwiftTermRemoteView(
                    session: session,
                    input: input,
                    onInput: { data in
                        chat.recordInput(data)
                        if input.ctrlActive {
                            input.ctrlActive = false
                        }
                    }
                )
                .opacity(1)
                .allowsHitTesting(true)
                .background(Color.black)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if presentation == .stream { commandComposer }
                specialKeysBar
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            input.isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            input.isKeyboardVisible = false
        }
        .onChange(of: session.outputChunks) { _, chunks in
            chat.ingest(chunks)
        }
        .onChange(of: session.state) { _, state in
            chat.update(state: state)
        }
        .task {
            startTerminal()
        }
        .onDisappear {
            session.close()
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                session.close()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Close terminal")

            VStack(alignment: .leading, spacing: 2) {
                Text("Task chat")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)

            Spacer(minLength: 4)

            Menu {
                Button { presentation = .stream } label: {
                    Label("Task chat", systemImage: "bubble.left.and.bubble.right")
                }
                Button { presentation = .raw } label: {
                    Label("Raw terminal", systemImage: "terminal")
                }
                Button { UIPasteboard.general.string = chat.latestText } label: {
                    Label("Copy transcript", systemImage: "doc.on.doc")
                }
                Button { startTerminal() } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .accessibilityLabel("Terminal actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.055))
    }

    private var presentationBar: some View {
        HStack(spacing: 6) {
            Text("SESSION")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 4)
            ForEach(RemoteTerminalPresentation.allCases) { mode in
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        presentation = mode
                    }
                } label: {
                    Label(mode.title, systemImage: mode.icon)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(presentation == mode ? .white : .white.opacity(0.55))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 32)
                        .background(
                            presentation == mode ? Color.white.opacity(0.15) : .clear,
                            in: Capsule(style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color(white: 0.08))
    }

    private var commandComposer: some View {
        HStack(spacing: 8) {
            Button {
                composerFocused.toggle()
            } label: {
                Image(systemName: composerFocused ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .accessibilityLabel(composerFocused ? "Hide keyboard" : "Show keyboard")

            TextField("Type a command…", text: $draft, axis: .vertical)
                .focused($composerFocused)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit(sendDraft)

            Button {
                guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
                draft += text
                composerFocused = true
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 38, height: 40)
            }
            .accessibilityLabel("Paste from iPhone clipboard")

            Button { sendDraft() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 40, height: 40)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.state != .open)
            .opacity(session.state == .open ? 1 : 0.45)
            .accessibilityLabel("Send command")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(white: 0.10))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5) }
    }

    private var specialKeysBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                specialKey("ctrl", isOn: input.ctrlActive) { input.toggleCtrl() }
                specialKey("esc") { send(bytes: [0x1B]) }
                specialKey("tab") { send(bytes: [0x09]) }
                specialKey("⌃C") { send(bytes: [0x03]) }
                specialKey("↑") { send(bytes: [0x1B, 0x5B, 0x41]) }
                specialKey("↓") { send(bytes: [0x1B, 0x5B, 0x42]) }
                specialKey("←") { send(bytes: [0x1B, 0x5B, 0x44]) }
                specialKey("→") { send(bytes: [0x1B, 0x5B, 0x43]) }
                specialKey("⌃D") { send(bytes: [0x04]) }
                specialKey("⌃Z") { send(bytes: [0x1A]) }
                specialKey("paste", system: "doc.on.clipboard") { pasteIntoTerminal() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(Color(white: 0.075))
    }

    private func specialKey(
        _ title: String,
        system: String? = nil,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 4) {
                if let system { Image(systemName: system).font(.system(size: 11, weight: .semibold)) }
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(isOn ? .black : .white.opacity(0.9))
            .padding(.horizontal, 11)
            .frame(minWidth: 40, minHeight: 38)
            .background(isOn ? Color.white : Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func send(bytes: [UInt8]) {
        let data = Data(bytes)
        chat.recordInput(data)
        session.send(data)
    }

    private func pasteIntoTerminal() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        let data = Data(text.utf8)
        chat.recordInput(data)
        session.send(data)
    }

    private func sendDraft() {
        let command = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, session.state == .open else { return }
        chat.submitCommand(command)
        session.send(Data((command + "\r").utf8))
        draft = ""
        composerFocused = true
    }

    private func startTerminal() {
        chat.reset()
        session.open()
    }

    private var statusText: String {
        switch session.state {
        case .idle: "Waiting to start"
        case .opening: "Opening shell…"
        case .open: "Connected"
        case .closed(let reason): reason ?? "Closed"
        case .failed: "Terminal error"
        }
    }

    private var statusColor: SwiftUI.Color {
        switch session.state {
        case .open: .green
        case .opening: .orange
        case .failed, .closed: .red
        case .idle: .white.opacity(0.45)
        }
    }
}

@MainActor
final class RemoteTerminalInputController: ObservableObject {
    @Published var isKeyboardVisible = true
    @Published var ctrlActive = false
    weak var terminalView: TerminalView?

    func toggleKeyboard() {
        guard let terminalView else { return }
        if isKeyboardVisible {
            _ = terminalView.resignFirstResponder()
            isKeyboardVisible = false
        } else {
            _ = terminalView.becomeFirstResponder()
            isKeyboardVisible = true
        }
    }

    func toggleCtrl() {
        let next = !ctrlActive
        ctrlActive = next
        terminalView?.controlModifier = next
        if next, !isKeyboardVisible {
            _ = terminalView?.becomeFirstResponder()
            isKeyboardVisible = true
        }
    }
}

private struct SwiftTermRemoteView: UIViewRepresentable {
    @ObservedObject var session: RemoteTerminalSession
    let input: RemoteTerminalInputController
    let onInput: (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, onInput: onInput)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView()
        view.terminalDelegate = context.coordinator
        view.backgroundColor = .black
        view.nativeForegroundColor = .white
        view.nativeBackgroundColor = .black
        context.coordinator.view = view
        input.terminalView = view
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.feedNewOutput(to: uiView)
        input.terminalView = uiView
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.resizeTask?.cancel()
        uiView.terminalDelegate = nil
    }

    @MainActor
    // SwiftTerm's TerminalViewDelegate requirements are nonisolated, but every
    // callback arrives on the main thread from a UIView and the bodies touch
    // main-actor state. Defer the isolation check to run time rather than
    // marking each method nonisolated.
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let session: RemoteTerminalSession
        var onInput: (Data) -> Void
        var lastOutputID: UInt64 = 0
        var lastGeneration: UInt64 = 0
        var resizeTask: Task<Void, Never>?
        weak var view: TerminalView?

        init(session: RemoteTerminalSession, onInput: @escaping (Data) -> Void) {
            self.session = session
            self.onInput = onInput
        }

        func feedNewOutput(to view: TerminalView) {
            if lastGeneration != session.generation {
                lastGeneration = session.generation
                lastOutputID = 0
            }
            let newChunks = session.outputChunks.filter { $0.id > lastOutputID }
            for chunk in newChunks {
                view.feed(byteArray: Array(chunk.data)[...])
                lastOutputID = chunk.id
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let input = Data(data)
            onInput(input)
            session.send(input)
        }

        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func itermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func bell(source: TerminalView) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            resizeTask?.cancel()
            resizeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled else { return }
                session.resize(
                    cols: min(max(newCols, 1), 240),
                    rows: min(max(newRows, 1), 120)
                )
            }
        }
    }
}
