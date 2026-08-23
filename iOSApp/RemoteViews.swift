import SwiftUI

struct RemoteRootView: View {
    let store: RemoteStore

    var body: some View {
        if store.isConnected {
            SessionNavigationView(store: store)
        } else {
            PairingView(store: store)
        }
    }
}

struct PairingView: View {
    let store: RemoteStore
    @State private var address = ""
    @State private var code = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    PairingHero()
                    VStack(spacing: 14) {
                        TextField("http://100.x.x.x:9475", text: $address)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        TextField("Six-digit pairing code", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: code) { _, value in
                                code = String(value.filter(\.isNumber).prefix(6))
                            }
                        Button {
                            Task { await store.connect(address: address, code: code) }
                        } label: {
                            Label(store.isConnecting ? "Connecting…" : "Connect to Mac", systemImage: "link")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(address.isEmpty || store.isConnecting)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    Text("Paste the full QR address or enter the address and code shown in Beet Code → Remote Sessions. Keep Tailscale connected on both devices.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 34)
            }
            .background(BeetTheme.wash.gradient)
            .alert("Connection problem", isPresented: errorBinding) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "Unknown error") }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    }
}

struct PairingHero: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .fill(.black)
                    .frame(width: 84, height: 84)
                    .shadow(color: BeetTheme.accent.opacity(0.28), radius: 18, y: 8)
                Image("BeetLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            Text("Beet Code Remote")
                .font(.largeTitle.bold())
                .tracking(-0.8)
            Text("Continue your Mac’s local and API coding sessions from iPhone or iPad.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

struct SessionNavigationView: View {
    let store: RemoteStore

    var body: some View {
        NavigationSplitView {
            SessionListView(store: store)
        } detail: {
            if store.selectedSession != nil {
                ConversationView(store: store)
            } else {
                ContentUnavailableView("Choose a session", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .alert("Remote Sessions", isPresented: errorBinding) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Unknown error") }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    }
}

struct SessionListView: View {
    let store: RemoteStore

    var body: some View {
        List(store.sessions) { session in
            Button {
                Task { await store.select(session) }
            } label: {
                SessionRow(session: session)
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if store.sessions.isEmpty {
                ContentUnavailableView("No sessions", systemImage: "tray", description: Text("Start a chat in Beet Code on your Mac."))
            }
        }
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Label(store.connectionLabel, systemImage: "circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(store.connectionLabel == "Connected" ? .green : .secondary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { try? await store.refresh() } }
                    Button("Revoke this device", systemImage: "iphone.slash", role: .destructive) {
                        Task { await store.revoke() }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .refreshable { try? await store.refresh() }
    }
}

struct SessionRow: View {
    let session: RemoteSessionSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.isRunning ? "sparkles" : "bubble.left")
                .foregroundStyle(session.isRunning ? BeetTheme.accentBright : .secondary)
                .frame(width: 28, height: 28)
                .background(BeetTheme.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.headline).lineLimit(2)
                Text("\(session.workspace) · \(session.messageCount) messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if session.isRunning { ProgressView().controlSize(.small) }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }
}

struct ConversationView: View {
    let store: RemoteStore
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            if let detail = store.selectedSession {
                MessageTranscript(detail: detail)
                if let pending = detail.pending {
                    PendingInteractionView(pending: pending, onResolve: { value in
                        Task { await store.resolvePending(value) }
                    })
                }
                RemoteComposer(
                    draft: $draft,
                    isRunning: detail.isRunning,
                    onSend: send,
                    onStop: { Task { await store.stop() } })
            }
        }
        .navigationTitle(store.selectedSession?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() {
        let message = draft
        Task {
            if await store.send(message) { draft = "" }
        }
    }
}

struct MessageTranscript: View {
    let detail: RemoteSessionDetail

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(detail.messages) { message in
                        MessageBubble(message: message)
                    }
                    if detail.isRunning, !detail.streamingText.isEmpty {
                        StreamingBubble(text: detail.streamingText, phase: detail.phase)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: detail.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: detail.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

struct MessageBubble: View {
    let message: RemoteMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 42) }
            VStack(alignment: .leading, spacing: 5) {
                Text(roleLabel).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(message.content).font(.body).textSelection(.enabled)
            }
            .padding(13)
            .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if message.role != "user" { Spacer(minLength: 24) }
        }
    }

    private var roleLabel: String {
        if message.role == "user" { return "You" }
        if message.role == "toolCall" || message.role == "toolResult" { return message.toolName ?? "Tool" }
        return "Beet Code"
    }

    private var background: Color {
        message.role == "user" ? BeetTheme.wash : Color(uiColor: .secondarySystemBackground)
    }
}

struct StreamingBubble: View {
    let text: String
    let phase: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack { ProgressView().controlSize(.small); Text(phase.capitalized) }
                    .font(.caption.weight(.semibold)).foregroundStyle(BeetTheme.accentBright)
                Text(text).font(.body).textSelection(.enabled)
            }
            .padding(13)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 24)
        }
    }
}

struct RemoteComposer: View {
    @Binding var draft: String
    let isRunning: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Beet Code", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Button(action: isRunning ? onStop : onSend) {
                Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(isRunning ? Color.red : BeetTheme.accent, in: Circle())
            }
            .disabled(!isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

struct PendingInteractionView: View {
    let pending: RemotePendingInteraction
    let onResolve: (String) -> Void
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "exclamationmark.shield.fill").font(.headline)
            Text(pending.summary ?? pending.content ?? "Beet Code needs your input.").font(.subheadline)
            if pending.kind == "question" {
                TextField("Your answer", text: $answer).textFieldStyle(.roundedBorder)
                Button("Send answer") { onResolve(answer) }.buttonStyle(.borderedProminent).disabled(answer.isEmpty)
            } else {
                HStack {
                    Button(pending.kind == "plan" ? "Approve plan" : "Approve") {
                        onResolve(pending.kind == "plan" ? "approve" : "approve")
                    }.buttonStyle(.borderedProminent)
                    if pending.kind == "approval" { Button("Decline", role: .destructive) { onResolve("decline") } }
                }
            }
        }
        .padding(14)
        .background(.orange.opacity(0.12))
    }

    private var title: String {
        switch pending.kind { case "question": "Question"; case "plan": "Plan ready"; default: "Approval needed" }
    }
}
