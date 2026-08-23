import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RemoteRootView: View {
    let store: RemoteStore
    @ViewBuilder var body: some View {
        if store.isConnected { SessionNavigationView(store: store) }
        else { PairingView(store: store) }
    }
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

struct AppearanceMenuButton: View {
    @AppStorage("remoteAppearance") private var appearance = RemoteAppearance.beet
    @Environment(\.remoteAppearance) private var current
    var body: some View {
        Menu {
            Picker("Appearance", selection: $appearance) {
                ForEach(RemoteAppearance.allCases) { option in
                    Label(option.label, systemImage: option.symbol).tag(option)
                }
            }
        } label: {
            Image(systemName: current.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(current == .beet ? Color.white : BeetTheme.secondaryText(current))
                .frame(width: 40, height: 40)
                .background(
                    current == .beet ? BeetTheme.surfaceStrong(current) : BeetTheme.surface(current),
                    in: Circle()
                )
                .overlay { Circle().stroke(BeetTheme.line(current).opacity(0.7), lineWidth: 0.75) }
                .shadow(color: .black.opacity(current == .light ? 0.08 : 0.18), radius: 9, y: 4)
                .contentShape(Circle())
        }
        .accessibilityLabel("Appearance, \(current.label)")
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
                            savedAddress: store.savedMacAddress,
                            isConnecting: store.isConnecting, onScan: { showScanner = true },
                            onReconnect: { Task { await store.connectSaved() } },
                            onForget: { store.forgetSavedMac() },
                            onConnect: { Task { await store.connect(address: address, code: code) } })
                        PairingAssurances()
                    }.frame(maxWidth: 560).padding(.horizontal, 18).padding(.vertical, 28).frame(maxWidth: .infinity)
                }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AppearanceMenuButton() } }
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
    let savedAddress: String?
    let isConnecting: Bool
    let onScan: () -> Void
    let onReconnect: () -> Void
    let onForget: () -> Void
    let onConnect: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            if let savedAddress {
                SavedMacReconnectCard(
                    address: savedAddress,
                    isConnecting: isConnecting,
                    onReconnect: onReconnect,
                    onForget: onForget
                )
                HStack(spacing: 10) {
                    Capsule().fill(BeetTheme.line(appearance)).frame(height: 1)
                    Text("or pair another Mac").font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
                    Capsule().fill(BeetTheme.line(appearance)).frame(height: 1)
                }
                .padding(.vertical, 2)
            }
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

struct SavedMacReconnectCard: View {
    @Environment(\.remoteAppearance) private var appearance
    let address: String
    let isConnecting: Bool
    let onReconnect: () -> Void
    let onForget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(Color.green.opacity(0.14)).frame(width: 38, height: 38)
                    Image(systemName: "desktopcomputer").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your paired Mac").font(.subheadline.weight(.semibold))
                    Text(address).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)).lineLimit(1)
                }
                Spacer()
                Menu {
                    Button("Forget this Mac", systemImage: "trash", role: .destructive, action: onForget)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 36, height: 36)
                }
                .foregroundStyle(BeetTheme.secondaryText(appearance))
            }
            Button(action: onReconnect) {
                HStack(spacing: 8) {
                    if isConnecting { ProgressView().tint(.white).controlSize(.small) }
                    Label(isConnecting ? "Looking for your Mac…" : "Connect again", systemImage: "bolt.horizontal.circle.fill")
                }
                .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(RemotePrimaryButtonStyle())
            .disabled(isConnecting)
        }
        .padding(14)
        .background(BeetTheme.surfaceStrong(appearance).opacity(0.7), in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).stroke(BeetTheme.line(appearance).opacity(0.75)) }
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
    @State private var showSharing = false
    private var visible: [RemoteSessionSummary] { search.isEmpty ? store.sessions : store.sessions.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.workspace.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        ZStack {
            RemoteBackdrop()
            ScrollView {
                LazyVStack(spacing: 18) {
                    SessionListHeader(onStart: { showStartSession = true })
                    ConnectionCard(store: store)
                    SearchField(text: $search)
                    if visible.isEmpty { RemoteEmptySessions(isSearching: !search.isEmpty) }
                    else { SessionGroup(sessions: visible) }
                }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 30)
            }.refreshable { try? await store.refresh() }
        }.navigationTitle("").navigationBarTitleDisplayMode(.inline).toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSharing = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share clipboard or files")
                    Menu {
                        AppearancePickerMenu()
                        Divider()
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { try? await store.refresh() } }
                        Button("Forget this Mac", systemImage: "iphone.slash", role: .destructive) { Task { await store.revoke() } }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Session options")
                }
            }
            .sheet(isPresented: $showStartSession) {
                StartSessionSheet(store: store) { sessionID in
                    showStartSession = false
                    onOpen(sessionID)
                }
            }
            .sheet(isPresented: $showSharing) { RemoteShareSheet(store: store) }
    }
}

struct SessionListHeader: View {
    let onStart: () -> Void
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sessions").font(.system(.largeTitle, design: .rounded, weight: .bold)).tracking(-0.7)
                Text("Continue on your Mac from anywhere.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(action: onStart) {
                Image(systemName: "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(LinearGradient(colors: [BeetTheme.accentBright, BeetTheme.accent], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                    .shadow(color: BeetTheme.accent.opacity(0.28), radius: 12, y: 6)
            }
            .buttonStyle(RemotePressButtonStyle())
            .accessibilityLabel("Start a new session")
        }
    }
}

struct SessionGroup: View {
    let sessions: [RemoteSessionSummary]
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sessions) { session in
                NavigationLink(value: session.id) { SessionRow(session: session) }
                    .buttonStyle(RemotePressButtonStyle())
                if session.id != sessions.last?.id {
                    Divider().overlay(BeetTheme.line(appearance)).padding(.leading, 60)
                }
            }
        }
        .padding(.horizontal, 4)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(BeetTheme.line(appearance).opacity(0.8), lineWidth: 0.75) }
        .shadow(color: .black.opacity(appearance == .light ? 0.055 : 0.14), radius: 18, y: 8)
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
        HStack(spacing: 11) {
            ZStack { Circle().fill(Color.green.opacity(0.13)).frame(width: 34, height: 34); Circle().fill(Color.green).frame(width: 9, height: 9).shadow(color: .green.opacity(0.55), radius: 4) }
            VStack(alignment: .leading, spacing: 2) { Text(store.connectionLabel == "Connected" ? "Mac connected" : store.connectionLabel).font(.subheadline.weight(.semibold)); Text("Private over Tailscale").font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)) }
            Spacer()
            if store.isRefreshing { ProgressView().controlSize(.small).frame(width: 36, height: 36) } else { Button { Task { try? await store.refresh() } } label: { Image(systemName: "arrow.clockwise").font(.subheadline.weight(.semibold)).frame(width: 36, height: 36).background(BeetTheme.surfaceStrong(appearance), in: Circle()) }.buttonStyle(RemotePressButtonStyle()).accessibilityLabel("Refresh sessions") }
        }.padding(.horizontal, 12).frame(minHeight: 58).background(BeetTheme.surface(appearance).opacity(0.86), in: RoundedRectangle(cornerRadius: 17, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(BeetTheme.line(appearance).opacity(0.75), lineWidth: 0.75) }
    }
}

struct SearchField: View {
    @Environment(\.remoteAppearance) private var appearance
    @Binding var text: String
    var body: some View {
        HStack(spacing: 9) { Image(systemName: "magnifyingglass").foregroundStyle(BeetTheme.secondaryText(appearance)); TextField("Search sessions", text: $text).textInputAutocapitalization(.never); if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(BeetTheme.secondaryText(appearance)) } }
            .padding(.horizontal, 13).frame(minHeight: 44).background(BeetTheme.surfaceStrong(appearance).opacity(0.72), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

struct SessionRow: View {
    let session: RemoteSessionSummary
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(session.isRunning ? BeetTheme.accent.opacity(0.18) : BeetTheme.surfaceStrong(appearance).opacity(0.72))
                    .frame(width: 42, height: 42)
                Image(systemName: session.isRunning ? "waveform" : "bubble.left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.isRunning ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(session.title).font(.body.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Text(session.workspace).lineLimit(1)
                    Text("·")
                    Text("\(session.messageCount) messages")
                    if session.isRunning { Text("·"); Text(session.phase.capitalized).foregroundStyle(BeetTheme.accentBright) }
                }
                .font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(Date(timeIntervalSince1970: session.updatedAt).formatted(.relative(presentation: .named)))
                .font(.caption2.weight(.medium)).foregroundStyle(BeetTheme.secondaryText(appearance)).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct RemotePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
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
    @State private var showSharing = false
    var body: some View {
        ZStack {
            RemoteBackdrop()
            if let detail = store.selectedSession, detail.id == sessionID {
                VStack(spacing: 0) {
                    ConversationStatus(detail: detail)
                    MessageTranscript(detail: detail)
                    if let pending = detail.pending { PendingInteractionView(pending: pending) { value in Task { await store.resolvePending(value) } } }
                }
            } else { ProgressView("Opening conversation…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.navigationTitle(store.sessions.first(where: { $0.id == sessionID })?.title ?? "Conversation").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.92), for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSharing = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share clipboard or files")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let detail = store.selectedSession, detail.id == sessionID {
                    RemoteComposer(draft: $draft, isRunning: detail.isRunning, onSend: send, onStop: { Task { await store.stop() } })
                }
            }
            .task(id: sessionID) { await store.select(sessionID: sessionID) }
            .sheet(isPresented: $showSharing) { RemoteShareSheet(store: store) }
    }
    private func send() { let message = draft; Task { if await store.send(message) { draft = "" } } }
}

struct ConversationStatus: View {
    let detail: RemoteSessionDetail
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(detail.isRunning ? Color.orange : Color.green).frame(width: 7, height: 7)
            Text(detail.isRunning ? detail.phase.capitalized : "Ready").fontWeight(.semibold)
            Text("·")
            Text(detail.modelID).lineLimit(1)
            Spacer(minLength: 8)
            Label("\(detail.messages.count)", systemImage: "text.bubble")
        }
        .font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
        .padding(.horizontal, 16).frame(minHeight: 34)
        .background(BeetTheme.surface(appearance).opacity(0.62))
    }
}

struct MessageTranscript: View {
    let detail: RemoteSessionDetail
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 24) {
                    ForEach(detail.messages) { MessageBubble(message: $0) }
                    if detail.isRunning { StreamingBubble(text: detail.streamingText, phase: detail.phase) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 16).padding(.vertical, 22).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: detail.streamingText) { _, _ in withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: detail.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

struct MessageBubble: View {
    let message: RemoteMessage
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        if message.role == "user" {
            HStack(alignment: .bottom) {
                Spacer(minLength: 46)
                MarkdownText(message.content)
                    .foregroundStyle(appearance == .light ? BeetTheme.accent : Color.white)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .background(BeetTheme.accent.opacity(appearance == .light ? 0.10 : 0.24), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(BeetTheme.accent.opacity(0.20), lineWidth: 0.75) }
            }
        }
        else if message.role == "toolCall" || message.role == "toolResult" { ToolMessageCard(message: message) }
        else {
            HStack(alignment: .top, spacing: 11) {
                Image("BeetLogo").resizable().scaledToFit().frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Beet Code").font(.caption.weight(.semibold)).foregroundStyle(BeetTheme.secondaryText(appearance))
                    MarkdownText(message.content)
                }
                Spacer(minLength: 4)
            }
        }
    }
}

struct MarkdownText: View {
    let content: String
    init(_ content: String) { self.content = content }
    var body: some View { if let value = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { Text(value).font(.body).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } else { Text(content).font(.body).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
}

struct ToolMessageCard: View {
    let message: RemoteMessage
    @Environment(\.remoteAppearance) private var appearance
    var body: some View { VStack(alignment: .leading, spacing: 8) { Label(message.toolName ?? "Tool activity", systemImage: message.role == "toolCall" ? "hammer" : "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(BeetTheme.accentBright); Text(message.content).font(.caption.monospaced()).lineSpacing(3).textSelection(.enabled).lineLimit(12) }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(BeetTheme.surfaceStrong(appearance).opacity(0.64), in: RoundedRectangle(cornerRadius: 14, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(BeetTheme.line(appearance).opacity(0.7), lineWidth: 0.75) } }
}

struct StreamingBubble: View {
    let text: String, phase: String
    @Environment(\.remoteAppearance) private var appearance
    var body: some View { HStack(alignment: .top, spacing: 11) { Image("BeetLogo").resizable().scaledToFit().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous)); VStack(alignment: .leading, spacing: 8) { HStack(spacing: 7) { ProgressView().controlSize(.small); Text(phase.capitalized) }.font(.caption.weight(.semibold)).foregroundStyle(BeetTheme.accentBright); if text.isEmpty { Text("Beet Code is working…").foregroundStyle(BeetTheme.secondaryText(appearance)) } else { MarkdownText(text) } }; Spacer(minLength: 4) } }
}

struct RemoteComposer: View {
    @Binding var draft: String
    let isRunning: Bool, onSend: () -> Void, onStop: () -> Void
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Continue this coding task…", text: $draft, axis: .vertical)
                .font(.body).lineLimit(1...6).padding(.leading, 14).padding(.vertical, 12)
            Button(action: isRunning ? onStop : onSend) {
                Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(isRunning ? Color.red : BeetTheme.accent, in: Circle())
            }
            .disabled(!isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(RemotePressButtonStyle())
            .padding(.trailing, 5).padding(.vertical, 5)
        }
        .frame(maxWidth: 720)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(BeetTheme.line(appearance).opacity(0.9), lineWidth: 0.75) }
        .shadow(color: .black.opacity(appearance == .light ? 0.10 : 0.22), radius: 18, y: 8)
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }
}

struct PendingInteractionView: View {
    let pending: RemotePendingInteraction
    let onResolve: (String) -> Void
    @Environment(\.remoteAppearance) private var appearance
    @State private var answer = ""
    var body: some View { VStack(alignment: .leading, spacing: 10) { Label(title, systemImage: "exclamationmark.shield.fill").font(.headline).foregroundStyle(.orange); Text(pending.summary ?? pending.content ?? "Beet Code needs your input.").font(.subheadline).lineSpacing(2); if pending.kind == "question" { TextField("Your answer", text: $answer).padding(11).background(BeetTheme.surfaceStrong(appearance), in: RoundedRectangle(cornerRadius: 11)); Button("Send answer") { onResolve(answer) }.buttonStyle(.borderedProminent).disabled(answer.isEmpty) } else { HStack { Button(pending.kind == "plan" ? "Approve plan" : "Approve") { onResolve("approve") }.buttonStyle(.borderedProminent); if pending.kind == "approval" { Button("Decline", role: .destructive) { onResolve("decline") } } } } }.padding(14).background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.5)) }.padding(.horizontal, 12).padding(.bottom, 8) }
    private var title: String { switch pending.kind { case "question": "Question"; case "plan": "Plan ready"; default: "Approval needed" } }
}

struct RemoteShareSheet: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var showFileImporter = false
    @State private var downloadedFile: DownloadedRemoteFile?
    @State private var confirmation: String?

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ShareSheetHeader()
                        ClipboardSharingSection(store: store, confirmation: $confirmation)
                        FileSharingSection(
                            store: store,
                            onChooseFile: { showFileImporter = true },
                            onDownload: download
                        )
                    }
                    .frame(maxWidth: 620).padding(.horizontal, 18).padding(.bottom, 30).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Share with Mac").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.loadSharing() }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task {
                    if await store.uploadFile(url) { confirmation = "Sent \(url.lastPathComponent) to your Mac." }
                }
            }
            .sheet(item: $downloadedFile) { item in RemoteActivityView(items: [item.url]) }
            .overlay(alignment: .bottom) {
                if let confirmation {
                    Text(confirmation).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        .background(Color.black.opacity(0.82), in: Capsule())
                        .padding(.bottom, 18).transition(.move(edge: .bottom).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation(.easeOut(duration: 0.18)) { self.confirmation = nil }
                        }
                }
            }
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.92), for: .navigationBar)
        }
    }

    private func download(_ file: RemoteSharedFileItem) {
        Task {
            if let url = await store.downloadFile(file) {
                downloadedFile = DownloadedRemoteFile(url: url)
            }
        }
    }
}

struct ShareSheetHeader: View {
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 34)).foregroundStyle(BeetTheme.accentBright)
            Text("Move work, not accounts.").font(.title2.weight(.bold)).tracking(-0.3)
            Text("Clipboard and files travel directly between this device and your paired Mac.")
                .font(.subheadline).foregroundStyle(BeetTheme.secondaryText(appearance)).lineSpacing(2)
        }
    }
}

struct ClipboardSharingSection: View {
    let store: RemoteStore
    @Binding var confirmation: String?
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemoteSectionLabel(title: "CLIPBOARD")
            HStack(spacing: 10) {
                ShareActionButton(title: "Paste from Mac", symbol: "arrow.down.doc", appearance: appearance) {
                    Task {
                        if let text = await store.copyMacClipboard() {
                            UIPasteboard.general.string = text
                            confirmation = text.isEmpty ? "The Mac clipboard is empty." : "Copied the Mac clipboard to this device."
                        }
                    }
                }
                ShareActionButton(title: "Send to Mac", symbol: "arrow.up.doc", appearance: appearance) {
                    let text = UIPasteboard.general.string ?? ""
                    Task {
                        if text.isEmpty { confirmation = "Copy some text on this device first." }
                        else if await store.sendClipboardToMac(text) { confirmation = "Sent this device’s clipboard to your Mac." }
                    }
                }
            }
        }
    }
}

struct ShareActionButton: View {
    let title: String
    let symbol: String
    let appearance: RemoteAppearance
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(BeetTheme.accentBright)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading).padding(.horizontal, 13)
            .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(BeetTheme.line(appearance).opacity(0.8), lineWidth: 0.75) }
        }
        .buttonStyle(RemotePressButtonStyle())
    }
}

struct FileSharingSection: View {
    let store: RemoteStore
    let onChooseFile: () -> Void
    let onDownload: (RemoteSharedFileItem) -> Void
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RemoteSectionLabel(title: "SHARED FILES")
                Spacer()
                if store.isSharing { ProgressView().controlSize(.small) }
            }
            Button(action: onChooseFile) {
                Label("Send a file to Mac", systemImage: "plus")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(RemoteSecondaryButtonStyle())

            if store.sharedFiles.isEmpty {
                Text("Files shared through Beet Code appear in Downloads › BeetCode Remote on your Mac.")
                    .font(.subheadline).foregroundStyle(BeetTheme.secondaryText(appearance)).lineSpacing(2).padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.sharedFiles) { file in
                        Button { onDownload(file) } label: { RemoteSharedFileRow(file: file) }
                            .buttonStyle(RemotePressButtonStyle())
                        if file.id != store.sharedFiles.last?.id { Divider().overlay(BeetTheme.line(appearance)).padding(.leading, 48) }
                    }
                }
                .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(BeetTheme.line(appearance).opacity(0.8), lineWidth: 0.75) }
            }
        }
    }
}

struct RemoteSharedFileRow: View {
    let file: RemoteSharedFileItem
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "doc.fill").foregroundStyle(BeetTheme.accentBright).frame(width: 36, height: 36)
                .background(BeetTheme.surfaceStrong(appearance).opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
            }
            Spacer()
            Image(systemName: "square.and.arrow.down").font(.subheadline.weight(.semibold)).foregroundStyle(BeetTheme.secondaryText(appearance))
        }
        .padding(.horizontal, 11).padding(.vertical, 9).contentShape(Rectangle())
    }
}

struct RemoteSectionLabel: View {
    @Environment(\.remoteAppearance) private var appearance
    let title: String
    var body: some View { Text(title).font(.caption2.weight(.bold)).tracking(0.9).foregroundStyle(BeetTheme.secondaryText(appearance)) }
}

struct DownloadedRemoteFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct RemoteActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
