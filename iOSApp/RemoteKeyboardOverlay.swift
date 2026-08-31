import AVFoundation
import Speech
import SwiftUI
import UIKit

/// Vamp-style remote keyboard: composer, shortcuts, latching modifiers, special keys.
struct RemoteKeyboardOverlay: View {
    var sendText: (String) -> Void
    var sendKey: (String, [String]) -> Void
    var onDismiss: () -> Void

    @State private var textInput = ""
    @State private var modifiers: Set<String> = []
    @StateObject private var dictation = RemoteDictation()
    @FocusState private var focused: Bool

    private static let accent = Color(white: 0.72)
    private static let panel = Color(white: 0.10)
    private static let chip = Color(white: 0.17)

    var body: some View {
        VStack(spacing: 10) {
            header
            composer
            quickActions
            shortcutRow
            modifierRow
            keyRow
            Text("modifiers apply to the next key, then release · cmd + typed letter sends the combo")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.38))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Self.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .onDisappear { focused = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Capsule().fill(Color.white.opacity(0.28)).frame(width: 28, height: 4)
            Text("keyboard")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Spacer()
            headerChip("focus") { focused = true }
            headerChip("hide kb") { focused = false }
            Button {
                focused = false
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Self.chip, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close the keyboard overlay")
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("type and send", text: $textInput)
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .focused($focused)
                .submitLabel(.send)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { sendComposer() }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Self.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button(action: sendComposer) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(textInput.isEmpty ? .white.opacity(0.35) : .white)
                    .frame(width: 40, height: 40)
                    .background(textInput.isEmpty ? Self.chip : Self.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(textInput.isEmpty)
            .accessibilityLabel("Send text to the Mac")
        }
    }

    private var quickActions: some View {
        HStack(spacing: 7) {
            rowButton("paste", icon: "doc.on.clipboard") {
                if let text = UIPasteboard.general.string, !text.isEmpty { sendText(text) }
            }
            rowButton("backspace", icon: "delete.left") { tap("delete") }
            rowButton("return", icon: "return") { tap("return") }
            rowButton("space", icon: "space") { sendText(" ") }
            Button {
                focused = false
                dictation.onText = sendText
                dictation.toggle()
            } label: {
                Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 36)
                    .background(dictation.isRecording ? Color(white: 0.34) : Self.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var shortcutRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                shortcut("⌘C copy") { sendKey("c", ["cmd"]) }
                shortcut("⌘V paste") { sendKey("v", ["cmd"]) }
                shortcut("⌘A all") { sendKey("a", ["cmd"]) }
                shortcut("⌘Z undo") { sendKey("z", ["cmd"]) }
                shortcut("⌘⇧3 shot") { sendKey("3", ["cmd", "shift"]) }
                shortcut("⌘⇧4 area") { sendKey("4", ["cmd", "shift"]) }
                shortcut("⌘␣ spotlight") { sendKey("space", ["cmd"]) }
                shortcut("⌘⇥ switch") { sendKey("tab", ["cmd"]) }
            }
        }
    }

    private var modifierRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                modifier("cmd")
                modifier("shift")
                modifier("opt")
                modifier("ctrl")
                modifier("fn")
            }
        }
    }

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                keyButton("esc", "escape")
                keyButton("tab", "tab")
                keyButton("del", "delete")
                keyButton("<-", "left")
                keyButton("->", "right")
                keyButton("up", "up")
                keyButton("down", "down")
                keyButton("f1", "f1")
                keyButton("f2", "f2")
                keyButton("f3", "f3")
                keyButton("f4", "f4")
                keyButton("f5", "f5")
                keyButton("f6", "f6")
                keyButton("f7", "f7")
                keyButton("f8", "f8")
                keyButton("f9", "f9")
                keyButton("f10", "f10")
                keyButton("f11", "f11")
                keyButton("f12", "f12")
                keyButton("home", "home")
                keyButton("end", "end")
                keyButton("pgup", "page_up")
                keyButton("pgdn", "page_down")
            }
        }
    }

    private func headerChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Self.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func rowButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Self.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func shortcut(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Self.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func modifier(_ name: String) -> some View {
        let active = modifiers.contains(name)
        return Button {
            if active { modifiers.remove(name) } else { modifiers.insert(name) }
            focused = true
        } label: {
            Text(name)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? .white : .white.opacity(0.82))
                .frame(minWidth: 52)
                .padding(.vertical, 9)
                .background(active ? Self.accent : Self.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func keyButton(_ title: String, _ key: String) -> some View {
        Button { tap(key) } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(minWidth: 46)
                .padding(.vertical, 9)
                .background(Self.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sendComposer() {
        let payload = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return }
        if !modifiers.isEmpty, payload.count == 1 {
            tap(payload.lowercased())
            textInput = ""
            return
        }
        sendText(payload)
        textInput = ""
        focused = true
    }

    private func tap(_ key: String) {
        sendKey(key, Array(modifiers))
        modifiers = []
        focused = true
    }
}

@MainActor
final class RemoteDictation: ObservableObject {
    @Published private(set) var isRecording = false
    var onText: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    private func start() async {
        guard !isRecording else { return }
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard speech, mic, let recognizer, recognizer.isAvailable else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            self.request = request
            let input = audioEngine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            transcript = ""
            isRecording = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if error != nil || (result?.isFinal ?? false) { self.finish() }
                }
            }
        } catch {
            finish()
        }
    }

    private func stop() {
        let text = transcript
        finish()
        if !text.isEmpty { onText?(text) }
    }

    private func finish() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
