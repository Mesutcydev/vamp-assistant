import SwiftUI

/// Live view into one bot's computer: what it produced, a shell inside it, and its workspace.
///
/// There is no screen to show. A bot computer is a headless Alpine container running
/// `sleep infinity` with CLI tooling only — no display server, no desktop — so "viewing the
/// Linux VM" means its output, its shell, and its files rather than a framebuffer.
struct BotConsolePanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case output = "Output"
        case shell = "Shell"
        case files = "Files"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .output: "text.alignleft"
            case .shell: "terminal"
            case .files: "folder"
            }
        }
    }

    let computer: BotComputerRecord?
    let run: BotRunRecord?
    let events: [BotRunEvent]

    @EnvironmentObject private var appState: AppState
    @State private var tab: Tab = .output
    @State private var command = ""
    @State private var transcript: [String] = []
    @State private var entries: [BotWorkspaceEntry] = []
    @State private var directory = ""
    @State private var preview: (name: String, contents: String)?
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            if let computer {
                content(for: computer)
            } else {
                placeholder("Prepare this bot's computer to open its console.")
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: computer?.id) { await loadFiles(reset: true) }
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Label("Console", systemImage: "rectangle.connected.to.line.below")
                .font(.headline)
            if let computer {
                Text(computer.backend.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(computer.state == .running ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(computer.state.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
        }
    }

    @ViewBuilder
    private func content(for computer: BotComputerRecord) -> some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }
        switch tab {
        case .output: outputTab
        case .shell: shellTab(computer)
        case .files: filesTab(computer)
        }
    }

    // MARK: Output

    private var outputTab: some View {
        ScrollView {
            // Lazy: a long-running bot accumulates hundreds of events, and a
            // plain VStack builds every row before the first one is on screen.
            LazyVStack(alignment: .leading, spacing: 8) {
                if let run, !run.latestOutput.isEmpty {
                    Text(run.latestOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(events.reversed()) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(event.createdAt, style: .time)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(event.phase)
                            .font(.caption.weight(.medium))
                        if let detail = event.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if run == nil, events.isEmpty {
                    placeholder("No runs yet. Start one to see its output here.")
                }
            }
        }
        .frame(minHeight: 180, maxHeight: 300)
    }

    // MARK: Shell

    private func shellTab(_ computer: BotComputerRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(transcript.isEmpty ? "Commands run in /workspace inside this bot's computer." : transcript.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 280)

            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                TextField("ls -la", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit { runCommand(computer) }
                if isBusy { ProgressView().controlSize(.small) }
            }
            .padding(8)
            .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .disabled(computer.state != .running && computer.backend == .appleContainer)

            if computer.state != .running, computer.backend == .appleContainer {
                Text("Start this bot's computer to run commands in it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Files

    private func filesTab(_ computer: BotComputerRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    directory = directory.contains("/")
                        ? String(directory[..<directory.lastIndex(of: "/")!])
                        : ""
                    Task { await loadFiles(reset: false) }
                } label: {
                    Image(systemName: "arrow.up.left")
                }
                .buttonStyle(.borderless)
                .disabled(directory.isEmpty)
                Text("/workspace" + (directory.isEmpty ? "" : "/\(directory)"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await loadFiles(reset: false) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reload this folder")
            }

            ScrollView {
                // Lazy: a workspace folder can hold thousands of entries.
                LazyVStack(alignment: .leading, spacing: 2) {
                    if entries.isEmpty {
                        placeholder("This folder is empty.")
                    }
                    ForEach(entries) { entry in
                        Button {
                            open(entry, in: computer)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                                    .foregroundStyle(entry.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                Text(entry.name)
                                    .font(.system(.caption, design: .monospaced))
                                Spacer()
                                if !entry.isDirectory {
                                    Text(ByteFormatter.bytes(Int64(entry.byteSize)))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: 240)

            if let preview {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.name).font(.caption.weight(.semibold))
                    ScrollView {
                        Text(preview.contents)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .padding(8)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func runCommand(_ computer: BotComputerRecord) {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        command = ""
        isBusy = true
        errorMessage = nil
        transcript.append("$ \(text)")
        Task {
            do {
                let output = try await appState.botComputers.exec(computerID: computer.id, command: text)
                transcript.append(output.isEmpty ? "(no output)" : output)
            } catch {
                errorMessage = error.localizedDescription
            }
            // Keep the transcript bounded; this is a console, not a log store.
            if transcript.count > 200 { transcript.removeFirst(transcript.count - 200) }
            isBusy = false
        }
    }

    private func open(_ entry: BotWorkspaceEntry, in computer: BotComputerRecord) {
        if entry.isDirectory {
            directory = entry.path
            preview = nil
            Task { await loadFiles(reset: false) }
        } else {
            Task {
                do {
                    preview = (
                        entry.name,
                        try await appState.botComputers.readWorkspaceFile(
                            computerID: computer.id, path: entry.path))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadFiles(reset: Bool) async {
        guard let computer else { return }
        if reset {
            directory = ""
            preview = nil
            transcript = []
        }
        do {
            entries = try await appState.botComputers.listWorkspace(
                computerID: computer.id, path: directory)
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }
}
