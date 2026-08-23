import SwiftUI
import UIKit

struct RemoteRootView: View {
    let store: RemoteStore
    var body: some View { store.isConnected ? AnyView(SessionNavigationView(store: store)) : AnyView(PairingView(store: store)) }
}

struct RemoteBackdrop: View {
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        BeetTheme.background(appearance)
            .overlay(alignment: .topLeading) {
                Circle().fill(BeetTheme.accentBright.opacity(appearance == .light ? 0.10 : 0.18))
                    .frame(width: 360, height: 360).blur(radius: 80).offset(x: -190, y: -210).accessibilityHidden(true)
            }.ignoresSafeArea()
    }
}

struct AppearanceSwitcher: View {
    @AppStorage("remoteAppearance") private var appearance = RemoteAppearance.beet
    @Environment(\.remoteAppearance) private var current
    var body: some View {
        HStack(spacing: 3) {
            ForEach(RemoteAppearance.allCases) { option in
                Button { withAnimation(.snappy(duration: 0.18)) { appearance = option } } label: {
                    Image(systemName: option.symbol).font(.caption.weight(.semibold)).frame(width: 34, height: 30)
                        .foregroundStyle(option == current ? Color.white : BeetTheme.secondaryText(current))
                        .background(option == current ? BeetTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel("\(option.label) appearance")
            }
        }.padding(3).background(BeetTheme.surfaceStrong(current), in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).stroke(BeetTheme.line(current)) }
    }
}

struct PairingView: View {
    let store: RemoteStore
    @State private var address = ""
    @State private var code = ""
    @State private var showScanner = false
    @State private var showManual = false
    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(spacing: 22) {
                        PairingHero()
                        PairingActions(address: $address, code: $code, showManual: $showManual,
                            isConnecting: store.isConnecting, onScan: { showScanner = true },
                            onConnect: { Task { await store.connect(address: address, code: code) } })
                        PairingAssurances()
                    }.frame(maxWidth: 560).padding(.horizontal, 18).padding(.vertical, 28).frame(maxWidth: .infinity)
                }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AppearanceSwitcher() } }
            .toolbarBackground(.hidden, for: .navigationBar)
            .alert("Connection problem", isPresented: errorBinding) { Button("OK") { store.errorMessage = nil } }
                message: { Text(store.errorMessage ?? "Unknown error") }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet(onScan: { value in
                    address = value; showScanner = false
                    Task { await store.connect(address: value, code: "") }
                }, onCancel: { showScanner = false })
            }
        }
    }
    private var errorBinding: Binding<Bool> { Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }) }
}

struct PairingHero: View {
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        VStack(spacing: 15) {
            Image("BeetLogo").resizable().scaledToFit().frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 20)).overlay { RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.14)) }
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
            VStack(spacing: 7) {
                Text("Beet Code Remote").font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-0.8)
                Text("Your Mac. In your pocket.").font(.headline.weight(.semibold)).foregroundStyle(BeetTheme.accentBright)
                Text("Continue local and API coding sessions securely from iPhone or iPad.")
                    .font(.body).foregroundStyle(BeetTheme.secondaryText(appearance)).multilineTextAlignment(.center).lineSpacing(2)
            }
        }
    }
}

struct PairingActions: View {
    @Environment(\.remoteAppearance) private var appearance
    @Binding var address: String
    @Binding var code: String
    @Binding var showManual: Bool
    let isConnecting: Bool
    let onScan: () -> Void
    let onConnect: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Button(action: onScan) { Label("Scan Beet Code QR", systemImage: "qrcode.viewfinder").font(.headline).frame(maxWidth: .infinity, minHeight: 52) }
                .buttonStyle(RemotePrimaryButtonStyle())
            Button { TailscaleLauncher.open() } label: { Label("Open Tailscale", systemImage: "network").font(.headline).frame(maxWidth: .infinity, minHeight: 50) }
                .buttonStyle(RemoteSecondaryButtonStyle())
            DisclosureGroup(isExpanded: $showManual) {
                VStack(spacing: 11) {
                    RemoteField(title: "Mac address", placeholder: "http://100.x.x.x:9475", text: $address, isCode: false)
                    RemoteField(title: "Pairing code", placeholder: "Six-digit code", text: $code, isCode: true)
                    Button(action: onConnect) {
                        HStack { if isConnecting { ProgressView().tint(.white) }; Label(isConnecting ? "Connecting…" : "Connect to Mac", systemImage: "link") }
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }.buttonStyle(RemotePrimaryButtonStyle()).disabled(address.isEmpty || isConnecting)
                }.padding(.top, 14)
            } label: {
                Label("Enter connection manually", systemImage: "keyboard").font(.subheadline.weight(.semibold))
                    .foregroundStyle(BeetTheme.secondaryText(appearance)).frame(minHeight: 44)
            }.tint(BeetTheme.secondaryText(appearance))
        }.padding(16).background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).stroke(BeetTheme.line(appearance)) }
            .shadow(color: .black.opacity(appearance == .light ? 0.08 : 0.18), radius: 22, y: 12)
    }
}

struct RemoteField: View {
    @Environment(\.remoteAppearance) private var appearance
    let title: String, placeholder: String
    @Binding var text: String
    let isCode: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(BeetTheme.secondaryText(appearance))
            TextField(placeholder, text: $text).textContentType(isCode ? .oneTimeCode : .URL).keyboardType(isCode ? .numberPad : .URL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().padding(.horizontal, 14).frame(minHeight: 50)
                .background(BeetTheme.surfaceStrong(appearance), in: RoundedRectangle(cornerRadius: 13))
                .overlay { RoundedRectangle(cornerRadius: 13).stroke(BeetTheme.line(appearance)) }
                .onChange(of: text) { _, value in if isCode { text = String(value.filter(\.isNumber).prefix(6)) } }
        }
    }
}

struct PairingAssurances: View {
    @Environment(\.remoteAppearance) private var appearance
    let items = [("lock.shield.fill", "Private", "Direct to your Mac"), ("checkmark.shield.fill", "In control", "Approve every action"), ("bolt.horizontal.fill", "No cloud relay", "Fast over Tailscale")]
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(items, id: \.1) { item in
                VStack(spacing: 6) { Image(systemName: item.0).foregroundStyle(BeetTheme.accentBright); Text(item.1).font(.caption.weight(.bold)); Text(item.2).font(.caption2).foregroundStyle(BeetTheme.secondaryText(appearance)).multilineTextAlignment(.center) }.frame(maxWidth: .infinity)
            }
        }.accessibilityElement(children: .combine)
    }
}

private enum TailscaleLauncher {
    @MainActor static func open() {
        let app = UIApplication.shared
        if let url = URL(string: "tailscale://"), app.canOpenURL(url) { app.open(url) }
        else if let url = URL(string: "https://apps.apple.com/app/tailscale/id1470499037") { app.open(url) }
    }
}

struct RemotePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white)
            .background(LinearGradient(colors: [BeetTheme.accentBright, BeetTheme.accent], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.975 : 1).opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct RemoteSecondaryButtonStyle: ButtonStyle {
    @Environment(\.remoteAppearance) private var appearance
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(BeetTheme.secondaryText(appearance))
            .background(BeetTheme.surfaceStrong(appearance), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(BeetTheme.line(appearance)) }
            .scaleEffect(configuration.isPressed ? 0.975 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SessionNavigationView: View {
    let store: RemoteStore
    @State private var path: [UUID] = []
    var body: some View {
        NavigationStack(path: $path) { SessionListView(store: store, onOpen: { path.append($0) }).navigationDestination(for: UUID.self) { ConversationView(store: store, sessionID: $0) } }
            .alert("Remote Sessions", isPresented: errorBinding) { Button("OK") { store.errorMessage = nil } }
                message: { Text(store.errorMessage ?? "Unknown error") }
    }
    private var errorBinding: Binding<Bool> { Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }) }
}

struct SessionListView: View {
    let store: RemoteStore
    let onOpen: (UUID) -> Void
    @State private var search = ""
    @State private var showStartSession = false
    private var visible: [RemoteSessionSummary] { search.isEmpty ? store.sessions : store.sessions.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.workspace.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        ZStack {
            RemoteBackdrop()
            ScrollView {
                LazyVStack(spacing: 14) {
                    ConnectionCard(store: store)
                    Button { showStartSession = true } label: {
                        Label("Start a new session", systemImage: "plus.bubble.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                    }.buttonStyle(RemotePrimaryButtonStyle())
                    SearchField(text: $search)
                    if visible.isEmpty { RemoteEmptySessions(isSearching: !search.isEmpty) }
                    else { ForEach(visible) { session in NavigationLink(value: session.id) { SessionCard(session: session) }.buttonStyle(.plain) } }
                }.padding(.horizontal, 16).padding(.bottom, 28)
            }.refreshable { try? await store.refresh() }
        }.navigationTitle("Remote sessions").navigationBarTitleDisplayMode(.large).toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Menu { AppearancePickerMenu(); Divider(); Button("Refresh", systemImage: "arrow.clockwise") { Task { try? await store.refresh() } }; Button("Revoke this device", systemImage: "iphone.slash", role: .destructive) { Task { await store.revoke() } } }
                    label: { Image(systemName: "ellipsis.circle.fill").font(.title3) }.accessibilityLabel("Session options")
            } }
            .sheet(isPresented: $showStartSession) {
                StartSessionSheet(store: store) { sessionID in
                    showStartSession = false
                    onOpen(sessionID)
                }
            }
    }
}

struct StartSessionSheet: View {
    let store: RemoteStore
    let onStarted: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var source = "local"
    @State private var selectedModelID = ""
    @State private var prompt = ""
    @State private var isStarting = false

    private var models: [RemoteStartModelOption] { store.startModels.filter { $0.source == source } }

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("New session").font(.largeTitle.bold()).tracking(-0.6)
                            Text("Choose the engine on your Mac and send the first prompt.").font(.subheadline).foregroundStyle(BeetTheme.secondaryText(appearance))
                        }
                        Picker("Model source", selection: $source) {
                            Label("Local", systemImage: "cpu").tag("local")
                            Label("API", systemImage: "cloud").tag("api")
                        }.pickerStyle(.segmented)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("MODEL").font(.caption2.bold()).tracking(0.8).foregroundStyle(BeetTheme.secondaryText(appearance))
                            if models.isEmpty {
                                ContentUnavailableView(source == "local" ? "No local models" : "No API models", systemImage: source == "local" ? "cpu" : "cloud", description: Text(source == "local" ? "Download a model on your Mac first." : "Configure an API provider on your Mac first."))
                                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(models) { model in
                                        Button { selectedModelID = model.id } label: {
                                            HStack(spacing: 12) {
                                                Image(systemName: selectedModelID == model.id ? "checkmark.circle.fill" : (source == "local" ? "cpu" : "cloud"))
                                                    .foregroundStyle(selectedModelID == model.id ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)).frame(width: 24)
                                                VStack(alignment: .leading, spacing: 3) { Text(model.name).font(.body.weight(.semibold)); Text(model.detail).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)) }
                                                Spacer()
                                            }.padding(13).contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                        if model.id != models.last?.id { Divider().overlay(BeetTheme.line(appearance)) }
                                    }
                                }.background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("FIRST PROMPT").font(.caption2.bold()).tracking(0.8).foregroundStyle(BeetTheme.secondaryText(appearance))
                            TextField("What should Beet Code work on?", text: $prompt, axis: .vertical).lineLimit(3...8).padding(14)
                                .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
                        }
                        Button { start() } label: {
                            HStack { if isStarting { ProgressView().tint(.white) }; Label(isStarting ? "Starting…" : "Start session", systemImage: "arrow.up.circle.fill") }
                                .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                        }.buttonStyle(RemotePrimaryButtonStyle()).disabled(selectedModelID.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isStarting)
                    }.padding(18)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .toolbarBackground(.hidden, for: .navigationBar)
            .task { await store.loadStartModels(); selectFirstModel() }
            .onChange(of: source) { _, _ in selectFirstModel() }
        }
    }

    private func selectFirstModel() { selectedModelID = models.first?.id ?? "" }
    private func start() {
        isStarting = true
        Task {
            if let id = await store.startSession(modelID: selectedModelID, message: prompt) { onStarted(id) }
            isStarting = false
        }
    }
}

struct ConnectionCard: View {
    let store: RemoteStore
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        HStack(spacing: 13) {
            ZStack { Circle().fill(Color.green.opacity(0.14)).frame(width: 42, height: 42); Circle().fill(Color.green).frame(width: 10, height: 10).shadow(color: .green.opacity(0.6), radius: 5) }
            VStack(alignment: .leading, spacing: 3) { Text(store.connectionLabel == "Connected" ? "Connected to your Mac" : store.connectionLabel).font(.subheadline.weight(.bold)); Text("Private remote control is active").font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)) }
            Spacer()
            if store.isRefreshing { ProgressView().controlSize(.small) } else { Button { Task { try? await store.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 40, height: 40) }.buttonStyle(.plain).accessibilityLabel("Refresh sessions") }
        }.padding(14).background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18)).overlay { RoundedRectangle(cornerRadius: 18).stroke(BeetTheme.line(appearance)) }
    }
}

struct SearchField: View {
    @Environment(\.remoteAppearance) private var appearance
    @Binding var text: String
    var body: some View {
        HStack(spacing: 9) { Image(systemName: "magnifyingglass").foregroundStyle(BeetTheme.secondaryText(appearance)); TextField("Search sessions", text: $text).textInputAutocapitalization(.never); if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(BeetTheme.secondaryText(appearance)) } }
            .padding(.horizontal, 13).frame(minHeight: 46).background(BeetTheme.surfaceStrong(appearance), in: RoundedRectangle(cornerRadius: 14)).overlay { RoundedRectangle(cornerRadius: 14).stroke(BeetTheme.line(appearance)) }
    }
}

struct SessionCard: View {
    let session: RemoteSessionSummary
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack { RoundedRectangle(cornerRadius: 12).fill(session.isRunning ? BeetTheme.accent.opacity(0.28) : BeetTheme.surfaceStrong(appearance)).frame(width: 46, height: 46); Image(systemName: session.isRunning ? "sparkles" : "bubble.left.fill").foregroundStyle(session.isRunning ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { Text(session.title).font(.body.weight(.semibold)).lineLimit(2); Spacer(minLength: 4); Text(Date(timeIntervalSince1970: session.updatedAt).formatted(.relative(presentation: .named))).font(.caption2.weight(.medium)).foregroundStyle(BeetTheme.secondaryText(appearance)) }
                Text(session.workspace).font(.subheadline).foregroundStyle(BeetTheme.secondaryText(appearance)).lineLimit(1)
                HStack(spacing: 7) { Label("\(session.messageCount) messages", systemImage: "text.bubble"); if session.isRunning { Text("•"); Label(session.phase.capitalized, systemImage: "waveform").foregroundStyle(BeetTheme.accentBright) } }.font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
            }
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(BeetTheme.secondaryText(appearance)).padding(.top, 17)
        }.padding(15).background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18)).overlay { RoundedRectangle(cornerRadius: 18).stroke(BeetTheme.line(appearance)) }.contentShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct RemoteEmptySessions: View {
    let isSearching: Bool
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        VStack(spacing: 10) { Image(systemName: isSearching ? "magnifyingglass" : "rectangle.stack.badge.plus").font(.largeTitle).foregroundStyle(BeetTheme.accentBright); Text(isSearching ? "No matching sessions" : "No sessions yet").font(.headline); Text(isSearching ? "Try another title or project name." : "Start a conversation in Beet Code on your Mac, then pull down to refresh.").font(.subheadline).foregroundStyle(BeetTheme.secondaryText(appearance)).multilineTextAlignment(.center) }
            .padding(30).frame(maxWidth: .infinity).background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct AppearancePickerMenu: View {
    @AppStorage("remoteAppearance") private var appearance = RemoteAppearance.beet
    var body: some View { Picker("Appearance", selection: $appearance) { ForEach(RemoteAppearance.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) } } }
}

struct ConversationView: View {
    let store: RemoteStore
    let sessionID: UUID
    @Environment(\.remoteAppearance) private var appearance
    @State private var draft = ""
    var body: some View {
        ZStack {
            RemoteBackdrop()
            if let detail = store.selectedSession, detail.id == sessionID {
                VStack(spacing: 0) { ConversationStatus(detail: detail); MessageTranscript(detail: detail); if let pending = detail.pending { PendingInteractionView(pending: pending) { value in Task { await store.resolvePending(value) } } }; RemoteComposer(draft: $draft, isRunning: detail.isRunning, onSend: send, onStop: { Task { await store.stop() } }) }
            } else { ProgressView("Opening conversation…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.navigationTitle(store.sessions.first(where: { $0.id == sessionID })?.title ?? "Conversation").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.92), for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .task(id: sessionID) { await store.select(sessionID: sessionID) }
    }
    private func send() { let message = draft; Task { if await store.send(message) { draft = "" } } }
}

struct ConversationStatus: View {
    let detail: RemoteSessionDetail
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        HStack(spacing: 8) { Circle().fill(detail.isRunning ? Color.orange : Color.green).frame(width: 7, height: 7); Text(detail.isRunning ? detail.phase.capitalized : "Ready"); Text("•"); Text(detail.modelID).lineLimit(1); Spacer(); Text("\(detail.messages.count) messages") }
            .font(.caption.weight(.medium)).foregroundStyle(BeetTheme.secondaryText(appearance)).padding(.horizontal, 16).frame(minHeight: 36).background(BeetTheme.surface(appearance).opacity(0.72))
    }
}

struct MessageTranscript: View {
    let detail: RemoteSessionDetail
    var body: some View {
        ScrollViewReader { proxy in ScrollView { LazyVStack(spacing: 18) { ForEach(detail.messages) { MessageBubble(message: $0) }; if detail.isRunning { StreamingBubble(text: detail.streamingText, phase: detail.phase) }; Color.clear.frame(height: 1).id("bottom") }.padding(.horizontal, 14).padding(.vertical, 18) }
            .defaultScrollAnchor(.bottom).onAppear { proxy.scrollTo("bottom", anchor: .bottom) }.onChange(of: detail.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }.onChange(of: detail.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) } }
    }
}

struct MessageBubble: View {
    let message: RemoteMessage
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        if message.role == "user" { HStack { Spacer(minLength: 42); bodyContent.padding(14).background(BeetTheme.accent, in: RoundedRectangle(cornerRadius: 18)) } }
        else if message.role == "toolCall" || message.role == "toolResult" { ToolMessageCard(message: message) }
        else { HStack(alignment: .top, spacing: 10) { Image("BeetLogo").resizable().scaledToFit().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 8)); bodyContent; Spacer(minLength: 8) } }
    }
    private var bodyContent: some View { VStack(alignment: .leading, spacing: 7) { Text(message.role == "user" ? "You" : "Beet Code").font(.caption.weight(.bold)).foregroundStyle(message.role == "user" ? Color.white.opacity(0.78) : BeetTheme.secondaryText(appearance)); MarkdownText(message.content).foregroundStyle(message.role == "user" ? Color.white : Color.primary) } }
}

struct MarkdownText: View {
    let content: String
    init(_ content: String) { self.content = content }
    var body: some View { if let value = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { Text(value).font(.body).lineSpacing(3).textSelection(.enabled) } else { Text(content).font(.body).lineSpacing(3).textSelection(.enabled) } }
}

struct ToolMessageCard: View {
    let message: RemoteMessage
    @Environment(\.remoteAppearance) private var appearance
    var body: some View { VStack(alignment: .leading, spacing: 8) { Label(message.toolName ?? "Tool activity", systemImage: message.role == "toolCall" ? "hammer.fill" : "checkmark.circle.fill").font(.caption.weight(.bold)).foregroundStyle(BeetTheme.accentBright); Text(message.content).font(.caption.monospaced()).lineSpacing(2).textSelection(.enabled).lineLimit(12) }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(BeetTheme.surfaceStrong(appearance), in: RoundedRectangle(cornerRadius: 14)).overlay { RoundedRectangle(cornerRadius: 14).stroke(BeetTheme.line(appearance)) } }
}

struct StreamingBubble: View {
    let text: String, phase: String
    @Environment(\.remoteAppearance) private var appearance
    var body: some View { HStack(alignment: .top, spacing: 10) { Image("BeetLogo").resizable().scaledToFit().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 8)); VStack(alignment: .leading, spacing: 8) { HStack(spacing: 7) { ProgressView().controlSize(.small); Text(phase.capitalized) }.font(.caption.weight(.bold)).foregroundStyle(BeetTheme.accentBright); if text.isEmpty { Text("Beet Code is working…").foregroundStyle(BeetTheme.secondaryText(appearance)) } else { MarkdownText(text) } }; Spacer(minLength: 8) } }
}

struct RemoteComposer: View {
    @Binding var draft: String
    let isRunning: Bool, onSend: () -> Void, onStop: () -> Void
    @Environment(\.remoteAppearance) private var appearance
    var body: some View { HStack(alignment: .bottom, spacing: 9) { TextField("Continue this coding task…", text: $draft, axis: .vertical).font(.body).lineLimit(1...5).padding(.horizontal, 14).padding(.vertical, 12).background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 17)).overlay { RoundedRectangle(cornerRadius: 17).stroke(BeetTheme.line(appearance)) }; Button(action: isRunning ? onStop : onSend) { Image(systemName: isRunning ? "stop.fill" : "arrow.up").font(.headline.weight(.bold)).foregroundStyle(.white).frame(width: 46, height: 46).background(isRunning ? Color.red : BeetTheme.accent, in: RoundedRectangle(cornerRadius: 15)) }.disabled(!isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).buttonStyle(.plain) }.padding(.horizontal, 12).padding(.vertical, 9).background(BeetTheme.background(appearance).opacity(0.94)) }
}

struct PendingInteractionView: View {
    let pending: RemotePendingInteraction
    let onResolve: (String) -> Void
    @Environment(\.remoteAppearance) private var appearance
    @State private var answer = ""
    var body: some View { VStack(alignment: .leading, spacing: 10) { Label(title, systemImage: "exclamationmark.shield.fill").font(.headline).foregroundStyle(.orange); Text(pending.summary ?? pending.content ?? "Beet Code needs your input.").font(.subheadline).lineSpacing(2); if pending.kind == "question" { TextField("Your answer", text: $answer).padding(11).background(BeetTheme.surfaceStrong(appearance), in: RoundedRectangle(cornerRadius: 11)); Button("Send answer") { onResolve(answer) }.buttonStyle(.borderedProminent).disabled(answer.isEmpty) } else { HStack { Button(pending.kind == "plan" ? "Approve plan" : "Approve") { onResolve("approve") }.buttonStyle(.borderedProminent); if pending.kind == "approval" { Button("Decline", role: .destructive) { onResolve("decline") } } } } }.padding(14).background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.5)) }.padding(.horizontal, 12).padding(.bottom, 8) }
    private var title: String { switch pending.kind { case "question": "Question"; case "plan": "Plan ready"; default: "Approval needed" } }
}
