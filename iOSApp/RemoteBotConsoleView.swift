import SwiftUI

/// Live view into one bot's computer from the phone: its shell, its workspace, and its output.
///
/// There is no screen to stream. A bot computer is a headless Alpine container running
/// `sleep infinity` with CLI tooling only, so "viewing the Linux VM" means these three things
/// rather than a framebuffer.
struct RemoteBotConsoleView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case shell = "Shell"
        case files = "Files"
        var id: String { rawValue }
    }

    let store: RemoteStore
    let computer: RemoteBotComputer

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .shell
    @State private var command = ""
    @State private var transcript: [String] = []
    @State private var entries: [RemoteBotWorkspaceEntry] = []
    @State private var directory = ""
    @State private var preview: (path: String, contents: String)?
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

                switch tab {
                case .shell: shell
                case .files: files
                }
            }
            .navigationTitle(computer.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadFiles() }
        }
    }

    private var shell: some View {
        VStack(spacing: 8) {
            ScrollViewReader { scroll in
                ScrollView {
                    Text(transcript.isEmpty
                         ? "Commands run in /workspace inside this bot's computer."
                         : transcript.joined(separator: "\n"))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .id("transcript")
                }
                .onChange(of: transcript.count) { _, _ in
                    withAnimation { scroll.scrollTo("transcript", anchor: .bottom) }
                }
            }

            HStack(spacing: 8) {
                TextField("ls -la", text: $command)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit(run)
                if isBusy {
                    ProgressView()
                } else {
                    Button("Run", action: run)
                        .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var files: some View {
        List {
            if !directory.isEmpty {
                Button {
                    directory = directory.contains("/")
                        ? String(directory[..<directory.lastIndex(of: "/")!])
                        : ""
                    Task { await loadFiles() }
                } label: {
                    Label("Up a level", systemImage: "arrow.up.left")
                }
            }
            Section("/workspace" + (directory.isEmpty ? "" : "/\(directory)")) {
                if entries.isEmpty {
                    Text("This folder is empty.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    Button {
                        open(entry)
                    } label: {
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                            Text(entry.name)
                                .font(.system(.footnote, design: .monospaced))
                            Spacer()
                            if !entry.isDirectory {
                                Text(byteText(entry.byteSize))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let preview {
                Section(preview.path) {
                    Text(preview.contents)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .refreshable { await loadFiles() }
    }

    private func byteText(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func run() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        command = ""
        isBusy = true
        errorMessage = nil
        transcript.append("$ \(text)")
        Task {
            do {
                let output = try await store.execInBotComputer(computer.id, command: text)
                transcript.append(output.isEmpty ? "(no output)" : output)
            } catch {
                errorMessage = error.localizedDescription
            }
            // Bounded: this is a console, not a log store.
            if transcript.count > 200 { transcript.removeFirst(transcript.count - 200) }
            isBusy = false
        }
    }

    private func open(_ entry: RemoteBotWorkspaceEntry) {
        if entry.isDirectory {
            directory = entry.path
            preview = nil
            Task { await loadFiles() }
        } else {
            Task {
                do {
                    preview = (path: entry.path, contents: try await store.botComputerFile(computer.id, path: entry.path))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadFiles() async {
        do {
            entries = try await store.botComputerFiles(computer.id, path: directory)
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }
}
