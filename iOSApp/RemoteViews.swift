import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RemoteRootView: View {
    let store: RemoteStore
    @ViewBuilder var body: some View {
#if DEBUG
        if ProcessInfo.processInfo.environment["VAMP_REMOTE_TEST_SCREEN"] == "disconnected-control" {
            RemoteControlView(store: store)
        } else if store.hasSavedConnection { SessionNavigationView(store: store) }
        else { PairingView(store: store) }
#else
        if store.hasSavedConnection { SessionNavigationView(store: store) }
        else { PairingView(store: store) }
#endif
    }
}

private struct KeyboardDismissToolbarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil)
                } label: {
                    Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityLabel("Hide keyboard")
            }
        }
    }
}

private extension View {
    func keyboardDismissToolbar() -> some View {
        modifier(KeyboardDismissToolbarModifier())
    }

    /// Shared companion glass: native material keeps the Vamp artwork present
    /// without letting its engraving compete with controls and text.
    func remoteGlass(
        _ appearance: RemoteAppearance,
        radius: CGFloat,
        strong: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(strong ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial), in: shape)
            .background(BeetTheme.surface(appearance).opacity(strong ? 0.34 : 0.22), in: shape)
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [.white.opacity(appearance == .light ? 0.58 : 0.18), BeetTheme.line(appearance)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(appearance == .light ? 0.10 : 0.28), radius: 22, y: 12)
    }
}

struct RemoteBackdrop: View {
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        GeometryReader { proxy in
            Image("WindowAtmosphere")
                .resizable()
                .scaledToFill()
                .saturation(0)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay(appearance == .light
                    ? Color.white.opacity(0.58)
                    : Color.black.opacity(0.46))
                .overlay {
                    LinearGradient(
                        colors: appearance == .light
                            ? [.white.opacity(0.20), .white.opacity(0.60)]
                            : [.black.opacity(0.02), .black.opacity(0.38)],
                        startPoint: .top,
                        endPoint: .bottom)
                }
                .accessibilityHidden(true)
        }
        .background(BeetTheme.background(appearance))
        .ignoresSafeArea()
    }
}

struct AppearanceMenuButton: View {
    @AppStorage("remoteAppearance") private var appearance = RemoteAppearance.dark
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
                .foregroundStyle(BeetTheme.secondaryText(current))
                .frame(width: 40, height: 40)
                .background(.thinMaterial, in: Circle())
                .background(BeetTheme.surface(current).opacity(0.2), in: Circle())
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
    @State private var showComputers = false
    @FocusState private var focusedField: PairingField?
    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(spacing: 22) {
                        PairingHero()
                        PairingActions(address: $address, code: $code, showManual: $showManual,
                            focusedField: $focusedField,
                            savedAddress: store.savedMacAddress,
                            isConnecting: store.isConnecting, onScan: { showScanner = true },
                            onReconnect: { Task { await store.connectSaved() } },
                            onForget: { store.forgetSavedMac() },
                            onConnect: { Task { await store.connect(address: address, code: code) } })
                        PairingAssurances()
                    }.frame(maxWidth: 560).padding(.horizontal, 18).padding(.vertical, 28).frame(maxWidth: .infinity)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if store.pairedComputers.count > 1 {
                        Button { showComputers = true } label: {
                            Image(systemName: "desktopcomputer.and.macbook")
                        }
                        .accessibilityLabel("Choose a Vamp Assistant computer")
                    }
                    AppearanceMenuButton()
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .alert(store.errorTitle, isPresented: errorBinding) { Button("OK") { store.errorMessage = nil } }
                message: { Text(store.errorMessage ?? "Unknown error") }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet(onScan: { value in
                    address = value; showScanner = false
                    Task { await store.connect(address: value, code: "") }
                }, onCancel: { showScanner = false })
            }
            .sheet(isPresented: $showComputers) { ComputerSwitcherSheet(store: store) }
            .keyboardDismissToolbar()
            .scrollDismissesKeyboard(.interactively)
        }
    }
    private var errorBinding: Binding<Bool> { Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }) }
}

struct PairingHero: View {
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        VStack(spacing: 15) {
            Color.clear.frame(width: 76, height: 76).accessibilityHidden(true)
            VStack(spacing: 7) {
                Text("Vamp Assistant")
                    .font(.largeTitle.weight(.bold))
                    .fontDesign(.serif)
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("Your Mac. In your pocket.").font(.headline.weight(.semibold)).foregroundStyle(BeetTheme.accentBright)
                Text("Continue Assistant, Code, and specialist bot sessions securely from iPhone or iPad.")
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
    var focusedField: FocusState<PairingField?>.Binding
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
            Button(action: onScan) { Label("Scan Vamp Assistant QR", systemImage: "qrcode.viewfinder").font(.headline).frame(maxWidth: .infinity, minHeight: 52) }
                .buttonStyle(RemotePrimaryButtonStyle())
            Button { TailscaleLauncher.open() } label: { Label("Open Tailscale", systemImage: "network").font(.headline).frame(maxWidth: .infinity, minHeight: 50) }
                .buttonStyle(RemoteSecondaryButtonStyle())
            DisclosureGroup(isExpanded: $showManual) {
                VStack(spacing: 11) {
                    RemoteField(title: "Mac address", placeholder: "http://192.168.1.x:9575", text: $address, field: .address, focusedField: focusedField)
                        .submitLabel(.next)
                        .onSubmit { focusedField.wrappedValue = .code }
                    RemoteField(title: "Pairing code", placeholder: "Six-digit code", text: $code, field: .code, focusedField: focusedField)
                        .submitLabel(.go)
                        .onSubmit { if !address.isEmpty && !code.isEmpty { onConnect() } }
                    Button(action: onConnect) {
                        HStack { if isConnecting { ProgressView().tint(.white) }; Label(isConnecting ? "Connecting…" : "Connect to Mac", systemImage: "link") }
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }.buttonStyle(RemotePrimaryButtonStyle()).disabled(address.isEmpty || code.count != 6 || isConnecting)
                }.padding(.top, 14)
            } label: {
                Label("Enter connection manually", systemImage: "keyboard").font(.subheadline.weight(.semibold))
                    .foregroundStyle(BeetTheme.secondaryText(appearance)).frame(minHeight: 44)
            }.tint(BeetTheme.secondaryText(appearance))
        }
        .padding(16)
        .remoteGlass(appearance, radius: 22, strong: true)
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
                    Circle().fill(Color.white.opacity(0.14)).frame(width: 38, height: 38)
                    Image(systemName: "desktopcomputer").font(.subheadline.weight(.semibold)).foregroundStyle(BeetTheme.accentBright)
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
        .remoteGlass(appearance, radius: 17)
    }
}

enum PairingField: Hashable {
    case address, code
}

struct RemoteField: View {
    @Environment(\.remoteAppearance) private var appearance
    let title: String, placeholder: String
    @Binding var text: String
    let field: PairingField
    var focusedField: FocusState<PairingField?>.Binding
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(BeetTheme.secondaryText(appearance))
            TextField(placeholder, text: $text)
                .textContentType(field == .code ? .oneTimeCode : .URL)
                .keyboardType(field == .code ? .numberPad : .URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focusedField, equals: field)
                .accessibilityLabel(title)
                .onChange(of: text) { _, value in
                    if field == .code {
                        let digits = value.filter(\.isNumber)
                        text = String(digits.prefix(6))
                    }
                }
                .padding(.horizontal, 14).frame(minHeight: 50)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 13).stroke(BeetTheme.line(appearance)) }
        }
    }
}

struct PairingAssurances: View {
    @Environment(\.remoteAppearance) private var appearance
    let items = [("lock.shield.fill", "Private", "Direct to your Mac"), ("checkmark.shield.fill", "In control", "Approve every action"), ("bolt.horizontal.fill", "No cloud relay", "LAN or Tailscale")]
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
            .background(BeetTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.975 : 1).opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct RemoteSecondaryButtonStyle: ButtonStyle {
    @Environment(\.remoteAppearance) private var appearance
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(BeetTheme.secondaryText(appearance))
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(BeetTheme.surfaceStrong(appearance).opacity(0.2), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(BeetTheme.line(appearance)) }
            .scaleEffect(configuration.isPressed ? 0.975 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SessionNavigationView: View {
    let store: RemoteStore
    @State private var path: [UUID] = []
    var body: some View {
        NavigationStack(path: $path) {
            SessionListView(store: store, onOpen: { path.append($0) })
                .navigationDestination(for: UUID.self) { ConversationView(store: store, sessionID: $0) }
        }
            .alert(store.errorTitle, isPresented: errorBinding) { Button("OK") { store.errorMessage = nil } }
                message: { Text(store.errorMessage ?? "Unknown error") }
            .keyboardDismissToolbar()
            .onReceive(NotificationCenter.default.publisher(for: .openRemoteSession)) { note in
                guard let id = note.object as? UUID else { return }
                if path.last != id { path = [id] }
            }
    }
    private var errorBinding: Binding<Bool> { Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }) }
}

struct SessionListView: View {
    let store: RemoteStore
    let onOpen: (UUID) -> Void
    @Environment(\.remoteAppearance) private var appearance
    @State private var search = ""
    @State private var showStartSession = false
    @State private var showSharing = false
    @State private var showComputers = false
    @State private var showControl = false
    @State private var showAppStream = false
    @State private var showBotRuns = false
    @State private var showDiagnostics = false
    @State private var startBotID = ""
    @State private var deferredSessionID: UUID?
    private var visible: [RemoteSessionSummary] { search.isEmpty ? store.sessions : store.sessions.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.workspace.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        ZStack {
            RemoteBackdrop()
            VStack(spacing: 0) {
                SessionControlHeader(
                    store: store,
                    search: $search,
                    onControl: { showControl = true },
                    onStart: {
                        startBotID = ""
                        showStartSession = true
                    })
                if !store.isConnected {
                    RemoteReconnectBanner(store: store)
                }

                ScrollView {
                    VStack(spacing: 16) {
                        RemoteHomeBotsSection { id in
                            startBotID = RemoteBotProfile.resolvedID(id) ?? ""
                            showStartSession = true
                        }
                        SessionSectionHeader(count: visible.count)
                        if visible.isEmpty { RemoteEmptySessions(isSearching: !search.isEmpty) }
                        else { SessionGroup(sessions: visible) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 30)
                }
                .refreshable { try? await store.refresh() }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showBotRuns = true } label: { Image(systemName: "person.3.sequence.fill") }
                        .accessibilityLabel("Specialist bots")
                    Button { showComputers = true } label: {
                        Image(systemName: "desktopcomputer.and.macbook")
                    }
                    .accessibilityLabel("Choose a Vamp Assistant computer")
                    Button { showSharing = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share clipboard or files")
                    Menu {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { try? await store.refresh() } }
                        Button("App Stream", systemImage: "macwindow.on.rectangle") { showAppStream = true }
                        Button("Control Diagnostics", systemImage: "stethoscope") { showDiagnostics = true }
                        Button("Forget this Mac", systemImage: "iphone.slash", role: .destructive) { Task { await store.revoke() } }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Session options")
                }
            }
            .sheet(isPresented: $showStartSession, onDismiss: openDeferredSession) {
                StartSessionSheet(store: store, initialBotID: startBotID) { sessionID in
                    deferredSessionID = sessionID
                    showStartSession = false
                }
            }
            .sheet(isPresented: $showSharing) { RemoteShareSheet(store: store) }
            .sheet(isPresented: $showBotRuns, onDismiss: openDeferredSession) {
                RemoteBotRunsView(store: store) { sessionID in
                    deferredSessionID = sessionID
                    showBotRuns = false
                }
            }
            .sheet(isPresented: $showComputers) { ComputerSwitcherSheet(store: store) }
            .sheet(isPresented: $showDiagnostics) {
                NavigationStack {
                    RemoteDiagnosticsSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showDiagnostics = false }
                            }
                        }
                }
            }
            .fullScreenCover(isPresented: $showControl) { RemoteControlView(store: store) }
            .fullScreenCover(isPresented: $showAppStream) {
                RemoteControlView(store: store, sourceMode: .application)
            }
    }

    private func openDeferredSession() {
        guard let sessionID = deferredSessionID else { return }
        deferredSessionID = nil
        // Navigation changes issued during sheet dismissal are occasionally
        // dropped by SwiftUI. The dismissal completion is the first stable
        // point at which the stack can accept the destination.
        Task { @MainActor in
            await Task.yield()
            onOpen(sessionID)
        }
    }
}

struct RemoteBotRunsView: View {
    private struct Specialist: Identifiable {
        let id: String
        let name: String
        let imageName: String
    }
    let store: RemoteStore
    let onOpen: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var prompts: [String: String] = [:]
    @State private var steer: [UUID: String] = [:]
    @State private var answers: [UUID: String] = [:]
    @State private var workflowPrompt = ""
    @State private var selectedModelID = ""

    private let specialists = [
        Specialist(id: "builder", name: "Builder", imageName: "BotBuilder"),
        Specialist(id: "reviewer", name: "Reviewer", imageName: "BotReviewer"),
        Specialist(id: "navigator", name: "Navigator", imageName: "BotNavigator"),
        Specialist(id: "researcher", name: "Researcher", imageName: "BotResearcher"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(spacing: 14) {
                        workflowCard
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 14)], spacing: 14) {
                            ForEach(specialists) { specialist in card(specialist) }
                        }
                    }
                    .padding(16)
                }
                .refreshable { try? await store.refresh() }
            }
            .navigationTitle("Bots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                if store.startModels.isEmpty { await store.loadStartModels() }
                selectedModelID = selectedModelID.isEmpty ? (store.startModels.first?.id ?? "") : selectedModelID
                try? await store.refresh()
            }
        }
        .presentationDetents([.large])
    }

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Adaptive workflow", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Picker("Model", selection: $selectedModelID) {
                ForEach(store.startModels) { Text($0.name).tag($0.id) }
            }
            TextField("Describe the complete outcome", text: $workflowPrompt, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            Button("Orchestrate") {
                let prompt = workflowPrompt
                Task {
                    if await store.orchestrateBots(modelID: selectedModelID, prompt: prompt) {
                        workflowPrompt = ""
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedModelID.isEmpty || workflowPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14)
        .remoteGlass(appearance, radius: 18, strong: true)
    }

    @ViewBuilder
    private func card(_ specialist: Specialist) -> some View {
        let run = store.botRuns.first { $0.profileID == specialist.id && !$0.isTerminal }
            ?? store.botRuns.first { $0.profileID == specialist.id }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(specialist.imageName)
                    .resizable()
                    .scaledToFit()
                    .saturation(0)
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.14), lineWidth: 0.75)
                    }
                    .accessibilityHidden(true)
                Text(specialist.name).font(.headline)
                Spacer()
                Circle().fill(run?.isTerminal == false ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance))
                    .frame(width: 8, height: 8)
            }
            if let run {
                HStack {
                    Text(run.phase).font(.caption.weight(.semibold))
                    Spacer()
                    if let queue = run.queuePosition { Text("Queue #\(queue)").font(.caption) }
                }
                Text(run.prompt).font(.subheadline).lineLimit(3)
                HStack(spacing: 8) {
                    Label(run.resourceClass ?? "remote", systemImage: "cpu")
                    if run.workflowID != nil {
                        Label("Workflow", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    if let dependencies = run.dependencyRunIDs, !dependencies.isEmpty {
                        Label("\(dependencies.count) deps", systemImage: "arrow.triangle.branch")
                    }
                    if let retry = run.retryCount, retry > 0 {
                        Label("Retry \(retry)", systemImage: "arrow.clockwise")
                    }
                }
                .font(.caption2).foregroundStyle(BeetTheme.secondaryText(appearance))
                if !run.latestOutput.isEmpty {
                    Text(run.latestOutput).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)).lineLimit(5)
                }
                if let gate = run.pendingInteraction ?? run.errorMessage {
                    Text(gate).font(.caption.weight(.semibold)).foregroundStyle(BeetTheme.accentBright)
                }
                if let trace = run.traceID {
                    Text("Trace \(trace.suffix(10)) · \(run.artifacts?.count ?? 0) artifacts")
                        .font(.caption2.monospaced())
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                }
                if run.state == "recoverable" {
                    Button("Resume from checkpoint") { Task { _ = await store.resumeBotRun(run.id) } }
                        .buttonStyle(.borderedProminent)
                } else if run.state == "needsApproval" {
                    HStack {
                        Button("Approve") { Task { _ = await store.approveBotRun(run.id, approved: true) } }
                            .buttonStyle(.borderedProminent)
                        Button("Decline", role: .destructive) { Task { _ = await store.approveBotRun(run.id, approved: false) } }
                    }
                } else if run.state == "needsInput" {
                    TextField("Answer the specialist", text: Binding(
                        get: { answers[run.id, default: ""] },
                        set: { answers[run.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Button("Send answer") {
                        let answer = answers[run.id, default: ""]
                        Task { if await store.answerBotRun(run.id, answer: answer) { answers[run.id] = "" } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(answers[run.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if !run.isTerminal {
                    TextField("Steer this run", text: Binding(
                        get: { steer[run.id, default: ""] },
                        set: { steer[run.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Steer") {
                            let message = steer[run.id, default: ""]
                            Task { if await store.steerBotRun(run.id, message: message) { steer[run.id] = "" } }
                        }.disabled(steer[run.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let sessionID = run.sessionID {
                            Button("Inspect") { onOpen(sessionID) }
                        }
                        Spacer()
                        Button("Stop", role: .destructive) { Task { _ = await store.stopBotRun(run.id) } }
                    }
                } else {
                    Divider()
                    Picker("Model", selection: $selectedModelID) {
                        ForEach(store.startModels) { Text($0.name).tag($0.id) }
                    }
                    TextField("New task for \(specialist.name)", text: Binding(
                        get: { prompts[specialist.id, default: ""] },
                        set: { prompts[specialist.id] = $0 }), axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                    Button("Start new run") {
                        let prompt = prompts[specialist.id, default: ""]
                        Task {
                            if await store.startBotRun(
                                profileID: specialist.id, modelID: selectedModelID, prompt: prompt) {
                                prompts[specialist.id] = ""
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedModelID.isEmpty || prompts[specialist.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Picker("Model", selection: $selectedModelID) {
                    ForEach(store.startModels) { Text($0.name).tag($0.id) }
                }
                TextField("Task for \(specialist.name)", text: Binding(
                    get: { prompts[specialist.id, default: ""] },
                    set: { prompts[specialist.id] = $0 }), axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                Button("Start run") {
                    let prompt = prompts[specialist.id, default: ""]
                    Task {
                        if await store.startBotRun(profileID: specialist.id, modelID: selectedModelID, prompt: prompt) {
                            prompts[specialist.id] = ""
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedModelID.isEmpty || prompts[specialist.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .remoteGlass(appearance, radius: 18, strong: true)
    }
}

struct ComputerSwitcherSheet: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var showPairing = false

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ComputerSwitcherIntro()
                        ForEach(store.pairedComputers) { computer in
                            ComputerChoiceCard(
                                computer: computer,
                                isActive: computer.id == store.activeComputerID,
                                isConnected: computer.id == store.activeComputerID && store.isConnected,
                                onSelect: {
                                    Task {
                                        await store.switchComputer(to: computer.id)
                                        if store.isConnected { dismiss() }
                                    }
                                },
                                onRemove: { store.removeComputer(computer.id) })
                        }
                        Button { showPairing = true } label: {
                            Label("Pair another computer", systemImage: "plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(RemotePrimaryButtonStyle())
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Your computers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
                        .sheet(isPresented: $showPairing) { PairAnotherMacSheet(store: store) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct PairAnotherMacSheet: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var address = ""
    @State private var code = ""
    @State private var showScanner = false
    @State private var showManual = true
    @FocusState private var focusedField: PairingField?

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(spacing: 16) {
                        Text("Scan the QR on your Mac, or enter its LAN or Tailscale address and pairing code.")
                            .font(.subheadline)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        PairingActions(
                            address: $address,
                            code: $code,
                            showManual: $showManual,
                            focusedField: $focusedField,
                            savedAddress: nil,
                            isConnecting: store.isConnecting,
                            onScan: { showScanner = true },
                            onReconnect: {},
                            onForget: {},
                            onConnect: {
                                Task {
                                    if await store.connect(address: address, code: code) { dismiss() }
                                }
                            })
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Pair another Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet(onScan: { value in
                    address = value
                    showScanner = false
                    Task {
                        if await store.connect(address: value, code: "") { dismiss() }
                    }
                }, onCancel: { showScanner = false })
            }
            .keyboardDismissToolbar()
            .scrollDismissesKeyboard(.interactively)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct RemoteReconnectBanner: View {
    let store: RemoteStore
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        Button {
            Task { await store.connectSaved() }
        } label: {
            HStack(spacing: 10) {
                if store.isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(BeetTheme.accentBright)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.connectionLabel == "Reconnecting…" ? "Reconnecting to Mac" : "Mac unreachable")
                        .font(.subheadline.weight(.semibold))
                    Text(store.connectionSubtitle)
                        .font(.caption)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                }
                Spacer(minLength: 8)
                Text("Retry")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BeetTheme.accentBright)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(BeetTheme.surface(appearance))
        }
        .buttonStyle(.plain)
        .disabled(store.isConnecting)
        .accessibilityLabel("Mac unreachable. Retry connection.")
    }
}

struct ComputerSwitcherIntro: View {
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer.and.macbook")
                .font(.title2.weight(.semibold))
                .foregroundStyle(BeetTheme.accentBright)
                .frame(width: 48, height: 48)
                .background(BeetTheme.surfaceStrong(appearance), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text("One remote, every Mac")
                    .font(.headline)
                Text("Switch computers without pairing again.")
                    .font(.subheadline)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }
}

struct ComputerChoiceCard: View {
    let computer: PairedBeetCodeComputer
    let isActive: Bool
    let isConnected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 13) {
                    Image(systemName: "macmini")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isActive ? Color.white : BeetTheme.accentBright)
                        .frame(width: 44, height: 44)
                        .background(isActive ? BeetTheme.accent : BeetTheme.surfaceStrong(appearance),
                                    in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(computer.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(computer.baseURL.host ?? computer.baseURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if isConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(BeetTheme.accentBright)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                    }
                }
            }
            .buttonStyle(RemotePressButtonStyle())
            Menu {
                Button("Remove computer", systemImage: "trash", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(BeetTheme.secondaryText(appearance))
        }
        .padding(14)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 19))
        .overlay {
            RoundedRectangle(cornerRadius: 19)
                .stroke(isActive ? BeetTheme.accentBright.opacity(0.75) : BeetTheme.line(appearance), lineWidth: isActive ? 1.25 : 0.75)
        }
    }
}

struct SessionControlHeader: View {
    @Bindable var store: RemoteStore
    @Binding var search: String
    let onControl: () -> Void
    let onStart: () -> Void
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vamp Assistant")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                Circle()
                    .fill(store.isConnected ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance))
                    .frame(width: 8, height: 8)
                    .shadow(
                        color: (store.isConnected ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)).opacity(0.35),
                        radius: 4)
                Button {
                    if !store.isConnected { Task { await store.connectSaved() } }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.connectionLabel == "Connected" ? "Mac connected" : store.connectionLabel)
                            .font(.subheadline.weight(.semibold))
                        Text(store.connectionSubtitle)
                            .font(.caption2)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.isConnected)
                .accessibilityLabel(store.isConnected ? "Mac connected" : "\(store.connectionLabel). \(store.connectionSubtitle)")
                Spacer(minLength: 8)
                Button(action: onControl) {
                    Image(systemName: "display.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(BeetTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(RemotePressButtonStyle())
                .disabled(!store.isConnected)
                .opacity(store.isConnected ? 1 : 0.45)
                .accessibilityLabel("Control Mac")
                .accessibilityHint(store.isConnected ? "Open a live view of this Mac" : "Connect to your Mac first")
                RemoteAppearanceSwitcher()
                Button { Task { try? await store.refresh() } } label: {
                    Group {
                        if store.isRefreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(RemoteChromeButtonStyle())
                .accessibilityLabel("Refresh sessions")
                Button(action: onStart) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(BeetTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(RemotePressButtonStyle())
                .disabled(!store.isConnected)
                .opacity(store.isConnected ? 1 : 0.45)
                .accessibilityLabel("Start a new session")
                .accessibilityHint(store.isConnected ? "" : "Connect to your Mac first")
            }
            SearchField(text: $search)
            RemoteModeSwitcher(mode: $store.sessionMode)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(BeetTheme.background(appearance).opacity(0.94))
        .overlay(alignment: .bottom) {
            Rectangle().fill(BeetTheme.line(appearance)).frame(height: 0.75)
        }
    }
}

struct RemoteAppearanceSwitcher: View {
    @AppStorage("remoteAppearance") private var appearance = RemoteAppearance.dark
    @Environment(\.remoteAppearance) private var current

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RemoteAppearance.allCases) { option in
                Button {
                    appearance = option
                } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(option == current ? Color.white : BeetTheme.secondaryText(current))
                        .frame(width: 28, height: 28)
                        .background(
                            option == current ? BeetTheme.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(RemotePressButtonStyle())
                .accessibilityLabel("\(option.label) appearance")
                .accessibilityAddTraits(option == current ? .isSelected : [])
            }
        }
        .padding(3)
        .background(BeetTheme.surfaceStrong(current), in: Capsule())
        .overlay { Capsule().stroke(BeetTheme.line(current).opacity(0.72), lineWidth: 0.75) }
        .shadow(color: .black.opacity(current == .light ? 0.07 : 0.16), radius: 7, y: 3)
        .animation(.easeOut(duration: 0.16), value: current)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Appearance")
    }
}

struct SessionSectionHeader: View {
    let count: Int
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        HStack {
            Text("SESSIONS")
                .font(.caption2.weight(.bold))
                .tracking(1.1)
            Spacer()
            Text("\(count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(BeetTheme.secondaryText(appearance))
        .padding(.horizontal, 10)
    }
}

struct SessionGroup: View {
    let sessions: [RemoteSessionSummary]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(sessions) { session in
                NavigationLink(value: session.id) { SessionRow(session: session) }
                    .buttonStyle(RemoteSessionButtonStyle())
            }
        }
    }
}

struct StartSessionSheet: View {
    @Bindable var store: RemoteStore
    let initialBotID: String
    let onStarted: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var source = "local"
    @State private var selectedModelID = ""
    @State private var selectedReasoningEffort: String?
    @State private var prompt = ""
    @State private var botComputers: [RemoteBotComputer] = []
    @State private var selectedBotComputerID: UUID?
    @State private var botComputerBusyID: UUID?
    @State private var keyProviderID = "openAI"
    @State private var keyDraft = ""
    @State private var isSavingKey = false
    @State private var keyMessage: String?
    @State private var selectedBotID = ""
    @State private var isStarting = false
    @State private var selectedWorkspacePath = ""
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var folderPathDraft = ""
    @State private var showPathEntry = false

    private var codeFolderMissing: Bool {
        store.sessionMode == .code
            && selectedBotComputerID == nil
            && (selectedWorkspacePath.isEmpty || !store.workspacesSupported)
    }

    private var canStart: Bool {
        store.isConnected
            && !selectedModelID.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isStarting
            && !codeFolderMissing
    }

    private var botProfile: RemoteBotProfile {
        RemoteBotProfile.profile(id: selectedBotID.isEmpty ? RemoteBotProfile.general.id : selectedBotID)
    }
    private var models: [RemoteStartModelOption] { store.startModels.filter { $0.source == source } }
    private var groupedAPIModels: [(detail: String, models: [RemoteStartModelOption])] {
        let groups = Dictionary(grouping: models, by: \.detail)
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            (key, groups[key]!.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }
    private var sourceIcon: String {
        switch source {
        case "chatgpt": "person.crop.circle"
        case "api": "cloud"
        default: "cpu"
        }
    }
    private var emptyModelsTitle: String {
        switch source {
        case "chatgpt": "No ChatGPT models"
        case "api": "No API models"
        default: "No local models"
        }
    }
    private var emptyModelsDescription: String {
        switch source {
        case "chatgpt": "Sign in with ChatGPT on your Mac, then refresh."
        case "api": "Configure an API provider on your Mac first."
        default: "Download a model on your Mac first."
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !store.isConnected {
                            RemoteReconnectBanner(store: store)
                        }
                        RemoteModeSwitcher(mode: $store.sessionMode)
                        Text(store.sessionMode == .chat
                             ? "Conversation only — no project folder on your Mac."
                             : "The agent stays inside one Mac folder.")
                            .font(.caption)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                        if store.sessionMode == .code {
                            workspaceSection
                        }
                        Text(botProfile.instruction == nil
                             ? "Plain chat — no specialist instructions."
                             : "\(botProfile.name) will \(botProfile.subtitle.lowercased()).")
                            .font(.subheadline)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                        RemoteBotChooser(selectedBotID: $selectedBotID)
                        RemoteBotStarters(
                            starters: botProfile.starters,
                            tint: botProfile.tint,
                            appearance: appearance,
                            prompt: $prompt)
                        Picker("Model source", selection: $source) {
                            Label("Local", systemImage: "cpu").tag("local")
                            Label("ChatGPT", systemImage: "person.crop.circle").tag("chatgpt")
                            Label("API", systemImage: "cloud").tag("api")
                        }.pickerStyle(.segmented)

                        botComputerSection

                        apiKeySection

                        VStack(alignment: .leading, spacing: 8) {
                            Text("MODEL").font(.caption2.bold()).tracking(0.8).foregroundStyle(BeetTheme.secondaryText(appearance))
                            if models.isEmpty {
                                ContentUnavailableView(emptyModelsTitle, systemImage: sourceIcon, description: Text(emptyModelsDescription))
                                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                            } else if source == "api", groupedAPIModels.count > 1 {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(groupedAPIModels, id: \.detail) { group in
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(group.detail.uppercased())
                                                .font(.caption2.bold()).tracking(0.8)
                                                .foregroundStyle(BeetTheme.secondaryText(appearance))
                                            modelList(group.models)
                                        }
                                    }
                                }
                            } else {
                                modelList(models)
                            }
                        }

                        if let selected = models.first(where: { $0.id == selectedModelID }),
                           let efforts = selected.reasoningEfforts, !efforts.isEmpty {
                            RemoteReasoningSelector(
                                modelName: selected.name,
                                efforts: efforts,
                                defaultEffort: selected.defaultReasoningEffort,
                                selection: $selectedReasoningEffort)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("FIRST PROMPT").font(.caption2.bold()).tracking(0.8).foregroundStyle(BeetTheme.secondaryText(appearance))
                            TextField("What should Vamp Assistant work on?", text: $prompt, axis: .vertical).lineLimit(3...8).padding(14)
                                .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
                        }
                        Button { start() } label: {
                            HStack { if isStarting { ProgressView().tint(.white) }; Label(isStarting ? "Starting…" : "Start session", systemImage: "arrow.up.circle.fill") }
                                .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                        }.buttonStyle(RemotePrimaryButtonStyle()).disabled(!canStart)
                    }.padding(18)
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                selectedBotID = initialBotID
                async let models: Void = store.loadStartModels()
                async let computers: Void = loadBotComputers()
                async let folders: Void = store.loadWorkspaces()
                _ = await (models, computers, folders)
                attachMatchingBotComputer()
                selectFirstModel()
                if selectedWorkspacePath.isEmpty {
                    selectedWorkspacePath = store.workspaces.first(where: { $0.isCurrent == true })?.path
                        ?? store.workspaces.first?.path
                        ?? ""
                }
            }
            .onChange(of: source) { _, _ in selectFirstModel() }
            .onChange(of: store.sessionMode) { _, mode in
                if mode == .chat { selectedBotComputerID = nil }
            }
            .onChange(of: selectedBotID) { _, _ in
                attachMatchingBotComputer()
            }
            .alert("New folder on Mac", isPresented: $showNewFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderName = "" }
                Button("Create") { createFolder() }
            } message: {
                Text(store.workspaceCreateParent.map { "Created inside \($0)." } ?? "Created in the app’s Documents folder on your Mac.")
            }
            .alert("Open a folder path", isPresented: $showPathEntry) {
                TextField("~/Developer/my-app", text: $folderPathDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { folderPathDraft = "" }
                Button("Open") { openFolderPath() }
            } message: {
                Text("The folder must already exist inside your Mac home directory.")
            }
            .keyboardDismissToolbar()
        }
    }

    private func selectFirstModel() {
        let first = source == "api" ? groupedAPIModels.first?.models.first : models.first
        selectedModelID = first?.id ?? ""
        selectedReasoningEffort = first?.defaultReasoningEffort
    }

    private func modelList(_ models: [RemoteStartModelOption]) -> some View {
        VStack(spacing: 0) {
            ForEach(models) { model in
                Button {
                    selectedModelID = model.id
                    selectedReasoningEffort = model.defaultReasoningEffort
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedModelID == model.id ? "checkmark.circle.fill" : sourceIcon)
                            .foregroundStyle(selectedModelID == model.id ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name).font(.body.weight(.semibold))
                            Text(model.detail).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
                        }
                        Spacer()
                    }.padding(13).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if model.id != models.last?.id { Divider().overlay(BeetTheme.line(appearance)) }
            }
        }.background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
    }

    @ViewBuilder
    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PROJECT FOLDER").font(.caption2.bold()).tracking(0.8)
                Spacer()
                if selectedBotComputerID != nil {
                    Text("Bot computer")
                        .font(.caption)
                }
            }.foregroundStyle(BeetTheme.secondaryText(appearance))
            if !store.workspacesSupported {
                Text("Update Vamp Assistant on your Mac to open or create a project folder from here.")
                    .font(.subheadline)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
            } else if selectedBotComputerID != nil {
                Text("This session uses the selected bot computer’s workspace and private browser.")
                    .font(.subheadline)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
            } else {
                if store.workspaces.isEmpty {
                    Text("No recent folders yet. Create one or open a path on your Mac.")
                        .font(.subheadline)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.workspaces) { folder in
                            Button {
                                selectedWorkspacePath = folder.path
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedWorkspacePath == folder.path ? "checkmark.circle.fill" : "folder.fill")
                                        .foregroundStyle(selectedWorkspacePath == folder.path ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance))
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(folder.name).font(.body.weight(.semibold))
                                        Text(folder.path).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)).lineLimit(1)
                                    }
                                    Spacer()
                                }.padding(13).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if folder.path != store.workspaces.last?.path {
                                Divider().overlay(BeetTheme.line(appearance))
                            }
                        }
                    }
                    .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
                }
                HStack(spacing: 10) {
                    Button { showNewFolder = true } label: {
                        Label("New folder", systemImage: "folder.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(RemoteSecondaryButtonStyle())
                    Button { showPathEntry = true } label: {
                        Label("Path", systemImage: "text.alignleft")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(RemoteSecondaryButtonStyle())
                }
            }
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty else { return }
        Task {
            if let created = await store.createWorkspace(name: name) {
                selectedWorkspacePath = created.path
            }
        }
    }

    private func openFolderPath() {
        let path = folderPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        folderPathDraft = ""
        guard !path.isEmpty else { return }
        Task {
            if let opened = await store.openWorkspace(path: path) {
                selectedWorkspacePath = opened.path
            }
        }
    }

    @ViewBuilder
    private var botComputerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BOT COMPUTER").font(.caption2.bold()).tracking(0.8)
                Spacer()
                Text(botComputers.isEmpty
                     ? "None prepared on Mac"
                     : (selectedBotComputerID == nil ? "Optional — tap to attach" : "Attached"))
                    .font(.caption)
            }.foregroundStyle(BeetTheme.secondaryText(appearance))
            if !botComputers.isEmpty {
                VStack(spacing: 0) {
                    ForEach(botComputers) { computer in
                        HStack(spacing: 11) {
                            Image(systemName: selectedBotComputerID == computer.id ? "checkmark.circle.fill" : "square.stack.3d.up.fill")
                                .foregroundStyle(selectedBotComputerID == computer.id ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayName(for: computer)).font(.body.weight(.semibold))
                                Text(botComputerSubtitle(computer))
                                    .font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
                            }
                            Spacer()
                            if computer.state == "running" {
                                Button(botComputerBusyID == computer.id ? "Stopping…" : "Stop") { stopBotComputer(computer) }
                                    .buttonStyle(.bordered)
                                    .disabled(botComputerBusyID != nil)
                            } else if computer.backend != "isolatedWorkspace" {
                                Button(botComputerBusyID == computer.id ? "Starting…" : "Start") { startBotComputer(computer) }
                                    .buttonStyle(.borderedProminent).tint(BeetTheme.accentBright)
                                    .disabled(botComputerBusyID != nil)
                            }
                        }
                        .padding(13)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard canAttachBotComputer(computer) else { return }
                            selectedBotComputerID = selectedBotComputerID == computer.id ? nil : computer.id
                            if selectedBotComputerID != nil { store.sessionMode = .code }
                        }
                        if computer.id != botComputers.last?.id { Divider().overlay(BeetTheme.line(appearance)) }
                    }
                }
                .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
            }
            if let profileID = RemoteBotProfile.resolvedID(selectedBotID),
               !botComputers.contains(where: { $0.profileID == profileID }) {
                Button {
                    prepareBotComputer(profileID: profileID)
                } label: {
                    Label("Create \(botProfile.name) computer on Mac", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(RemoteSecondaryButtonStyle())
                .disabled(botComputerBusyID != nil || !store.isConnected)
            } else if botComputers.isEmpty {
                Button {
                    prepareBotComputer(profileID: nil)
                } label: {
                    Label("Prepare bot computers on Mac", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(RemoteSecondaryButtonStyle())
                .disabled(botComputerBusyID != nil || !store.isConnected)
            }
        }
    }

    private func displayName(for computer: RemoteBotComputer) -> String {
        computer.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Beet") == .orderedSame
            ? "Assistant computer"
            : computer.name
    }

    private func canAttachBotComputer(_ computer: RemoteBotComputer) -> Bool {
        computer.state == "running" || computer.backend == "isolatedWorkspace"
    }

    private func botComputerSubtitle(_ computer: RemoteBotComputer) -> String {
        let backend: String
        switch computer.backend {
        case "appleContainer": backend = "Linux micro-VM"
        case "isolatedWorkspace": backend = "Private workspace"
        case "macOSVirtualMachine": backend = "macOS VM"
        default: backend = computer.backend
        }
        return computer.state.capitalized + " · " + backend + " · private browser"
    }

    private func attachMatchingBotComputer() {
        guard let profileID = RemoteBotProfile.resolvedID(selectedBotID) else { return }
        if let match = botComputers.first(where: { $0.profileID == profileID && canAttachBotComputer($0) }) {
            selectedBotComputerID = match.id
            store.sessionMode = .code
        }
    }

    private func prepareBotComputer(profileID: String?) {
        botComputerBusyID = UUID()
        Task {
            let computers = await store.prepareBotComputers(profileID: profileID)
            if !computers.isEmpty {
                botComputers = computers
                attachMatchingBotComputer()
            } else {
                await loadBotComputers()
            }
            botComputerBusyID = nil
        }
    }

    private func loadBotComputers() async {
        if let envelope = await store.botComputers() {
            botComputers = envelope.computers
            if let selected = selectedBotComputerID,
               !envelope.computers.contains(where: {
                   $0.id == selected && ($0.state == "running" || $0.backend == "isolatedWorkspace")
               }) {
                selectedBotComputerID = nil
            }
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("API KEY").font(.caption2.bold()).tracking(0.8).foregroundStyle(BeetTheme.secondaryText(appearance))
            HStack(spacing: 8) {
                Picker("Provider", selection: $keyProviderID) {
                    Text("OpenAI").tag("openAI")
                    Text("Gemini").tag("gemini")
                    Text("OpenRouter").tag("openRouter")
                    Text("Anthropic").tag("anthropic")
                    Text("DeepSeek").tag("deepSeek")
                    Text("OpenCode Zen").tag("openCode")
                    Text("OpenCode Go").tag("openCodeGo")
                }.pickerStyle(.menu)
                SecureField("Paste key", text: $keyDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(isSavingKey ? "Saving…" : "Save") { saveAPIKey() }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingKey)
            }
            if let keyMessage { Text(keyMessage).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)) }
            Text("Stored securely in the Mac Keychain; the key is never saved on this device or in chat.")
                .font(.caption2).foregroundStyle(BeetTheme.secondaryText(appearance))
        }
    }

    private func saveAPIKey() {
        isSavingKey = true
        let key = keyDraft
        Task {
            let saved = await store.saveAPIKey(providerID: keyProviderID, key: key)
            if saved {
                keyDraft = ""
                source = "api"
                await store.loadStartModels()
                selectFirstModel()
                let count = store.startModels.filter { $0.source == "api" }.count
                keyMessage = count == 0
                    ? "Saved on Mac, but no models came back yet."
                    : "Saved. Loaded \(count) API models."
            } else {
                keyMessage = "Could not save the key."
            }
            isSavingKey = false
        }
    }

    private func startBotComputer(_ computer: RemoteBotComputer) {
        botComputerBusyID = computer.id
        Task {
            if await store.startBotComputer(computer.id) {
                await loadBotComputers()
                selectedBotComputerID = computer.id
                store.sessionMode = .code
            }
            botComputerBusyID = nil
        }
    }

    private func stopBotComputer(_ computer: RemoteBotComputer) {
        botComputerBusyID = computer.id
        Task {
            if await store.stopBotComputer(computer.id) {
                await loadBotComputers()
                if selectedBotComputerID == computer.id { selectedBotComputerID = nil }
            }
            botComputerBusyID = nil
        }
    }
    private func start() {
        isStarting = true
        store.reasoningEffort = selectedReasoningEffort
        let firstMessage = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if let id = await store.startSession(
                modelID: selectedModelID,
                message: firstMessage,
                botProfileID: RemoteBotProfile.resolvedID(selectedBotID),
                botComputerID: selectedBotComputerID,
                workspacePath: store.sessionMode == .code && selectedBotComputerID == nil
                    ? selectedWorkspacePath : nil,
                chatOnly: store.sessionMode == .chat && selectedBotComputerID == nil) { onStarted(id) }
            isStarting = false
        }
    }
}

private struct RemoteBotProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let imageName: String
    let starters: [String]
    let instruction: String?

    static let general = RemoteBotProfile(
        id: "general", name: "Assistant", subtitle: "Balanced assistant",
        imageName: "VampBackdrop",
        starters: ["Plan this task", "Explain this project", "Help me decide"],
        instruction: nil)
    static let profiles: [RemoteBotProfile] = [
        general,
        .init(id: "builder", name: "Builder", subtitle: "Build and fix",
              imageName: "BotBuilder",
              starters: ["Fix the current issue", "Build this feature", "Run the tests"],
              instruction: "Work as a focused software builder. Inspect the existing project, implement the request completely, preserve unrelated work, and verify the result."),
        .init(id: "reviewer", name: "Reviewer", subtitle: "Diff and risks",
              imageName: "BotReviewer",
              starters: ["Review my changes", "Check for regressions", "Audit this diff"],
              instruction: "Work as a careful code reviewer. Inspect the current changes, identify concrete bugs and regressions first, and give evidence-backed recommendations. Do not edit unless asked."),
        .init(id: "navigator", name: "Navigator", subtitle: "Browser control",
              imageName: "BotNavigator",
              starters: ["Open and inspect this site", "Test this web flow", "Compare these pages"],
              instruction: "Work as a browser navigator. Use the available browser tools directly, keep actions scoped to the request, and summarize what changed or what you found."),
        .init(id: "researcher", name: "Researcher", subtitle: "Sources and synthesis",
              imageName: "BotResearcher",
              starters: ["Research this topic", "Compare the best options", "Verify this claim"],
              instruction: "Work as a technical researcher. Prefer primary sources, compare evidence, distinguish facts from inference, and return concise actionable findings."),
    ]

    static func profile(id: String) -> RemoteBotProfile {
        profiles.first(where: { $0.id == id }) ?? general
    }

    static func resolvedID(_ id: String?) -> String? {
        guard let id, !id.isEmpty, id != general.id else { return nil }
        return id
    }

    var tint: Color {
        BeetTheme.accentBright
    }
}

private struct RemoteBotThumbnail: View {
    let profile: RemoteBotProfile
    var size: CGFloat = 56

    var body: some View {
        Image(profile.imageName)
            .resizable()
            .scaledToFit()
            .saturation(0)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.75)
            }
            .shadow(color: profile.tint.opacity(0.22), radius: 8, y: 4)
            .accessibilityHidden(true)
    }
}

private struct RemoteHomeBotsSection: View {
    let onSelect: (String) -> Void
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BOTS")
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                Text("optional")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(BeetTheme.surfaceStrong(appearance), in: Capsule())
            }
            .foregroundStyle(BeetTheme.secondaryText(appearance))
            .padding(.horizontal, 10)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(RemoteBotProfile.profiles) { profile in
                        RemoteHomeBotCard(profile: profile, appearance: appearance) {
                            onSelect(profile.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct RemoteHomeBotCard: View {
    let profile: RemoteBotProfile
    let appearance: RemoteAppearance
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RemoteBotThumbnail(profile: profile, size: 72)
                Text(profile.name)
                    .font(.caption.weight(.semibold))
                Text(profile.subtitle)
                    .font(.caption2)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(width: 92)
            .padding(.vertical, 10)
            .background(
                BeetTheme.surface(appearance).opacity(0.55),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(BeetTheme.line(appearance).opacity(0.55), lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(RemotePressButtonStyle())
        .accessibilityLabel("\(profile.name), \(profile.subtitle)")
        .accessibilityHint(profile.id == RemoteBotProfile.general.id
                           ? "Starts a plain chat with no specialist bot"
                           : "Starts a new session with this bot")
    }
}

private struct RemoteBotChooser: View {
    @Binding var selectedBotID: String
    @Environment(\.remoteAppearance) private var appearance

    private var effectiveID: String {
        selectedBotID.isEmpty ? RemoteBotProfile.general.id : selectedBotID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BOT").font(.caption2.bold()).tracking(0.8)
                Spacer()
                Text(effectiveID == RemoteBotProfile.general.id ? "None — plain chat" : RemoteBotProfile.profile(id: effectiveID).name)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(BeetTheme.secondaryText(appearance))
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(RemoteBotProfile.profiles) { profile in
                        let isSelected = effectiveID == profile.id
                        Button {
                            selectedBotID = RemoteBotProfile.resolvedID(profile.id) ?? ""
                        } label: {
                            VStack(spacing: 6) {
                                RemoteBotThumbnail(profile: profile, size: 48)
                                Text(profile.name)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(isSelected ? profile.tint : .primary)
                            }
                            .frame(width: 76)
                            .padding(.vertical, 8)
                            .background(
                                BeetTheme.surface(appearance).opacity(isSelected ? 0.96 : 0.5),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(isSelected ? profile.tint.opacity(0.7) : BeetTheme.line(appearance).opacity(0.5), lineWidth: isSelected ? 1.25 : 0.75)
                            }
                        }
                        .buttonStyle(RemotePressButtonStyle())
                        .accessibilityLabel(profile.name)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct RemoteBotStarters: View {
    let starters: [String]
    let tint: Color
    let appearance: RemoteAppearance
    @Binding var prompt: String

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(starters, id: \.self) { starter in
                    Button(starter) {
                        prompt = starter
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                    .padding(.horizontal, 11)
                    .frame(minHeight: 34)
                    .background(BeetTheme.surfaceStrong(appearance), in: Capsule())
                    .overlay(Capsule().stroke(tint.opacity(0.16), lineWidth: 0.75))
                    .buttonStyle(RemotePressButtonStyle())
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Suggested tasks")
    }
}

struct RemoteReasoningSelector: View {
    let modelName: String
    let efforts: [String]
    let defaultEffort: String?
    @Binding var selection: String?
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Reasoning", systemImage: "brain.head.profile")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(selection ?? defaultEffort ?? "Auto")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(BeetTheme.accentBright)
            }
            Text("Choose how much thinking \(modelName) should use.")
                .font(.caption)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    reasoningButton("Auto", value: nil)
                    ForEach(efforts, id: \.self) { effort in
                        reasoningButton(effort.capitalized, value: effort)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(13)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
    }

    private func reasoningButton(_ title: String, value: String?) -> some View {
        let selected = selection == value
        return Button(title) { selection = value }
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? Color.white : BeetTheme.secondaryText(appearance))
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(
                selected ? BeetTheme.accent : BeetTheme.surfaceStrong(appearance),
                in: Capsule())
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ConnectionCard: View {
    let store: RemoteStore
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        HStack(spacing: 11) {
            ZStack { Circle().fill((store.isConnected ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)).opacity(0.13)).frame(width: 34, height: 34); Circle().fill(store.isConnected ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)).frame(width: 9, height: 9).shadow(color: (store.isConnected ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)).opacity(0.55), radius: 4) }
            VStack(alignment: .leading, spacing: 2) { Text(store.connectionLabel == "Connected" ? "Mac connected" : store.connectionLabel).font(.subheadline.weight(.semibold)); Text(store.connectionSubtitle).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)) }
            Spacer()
            if store.isRefreshing { ProgressView().controlSize(.small).frame(width: 36, height: 36) } else { Button { Task { try? await store.refresh() } } label: { Image(systemName: "arrow.clockwise").font(.subheadline.weight(.semibold)).frame(width: 36, height: 36).background(BeetTheme.surfaceStrong(appearance), in: Circle()) }.buttonStyle(RemotePressButtonStyle()).accessibilityLabel("Refresh sessions") }
        }.padding(.horizontal, 12).frame(minHeight: 58).background(BeetTheme.surface(appearance).opacity(0.86), in: RoundedRectangle(cornerRadius: 17, style: .continuous)).overlay { RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(BeetTheme.line(appearance).opacity(0.75), lineWidth: 0.75) }
    }
}

struct RemoteModeSwitcher: View {
    @Binding var mode: RemoteSessionMode
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RemoteSessionMode.allCases) { option in
                Button {
                    mode = option
                } label: {
                    Label(option.title, systemImage: option.symbol)
                        .font(.subheadline.weight(mode == option ? .semibold : .medium))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(mode == option ? Color.white : BeetTheme.secondaryText(appearance))
                        .background(
                            mode == option ? BeetTheme.accent : BeetTheme.surfaceStrong(appearance),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(RemotePressButtonStyle())
                .accessibilityAddTraits(mode == option ? .isSelected : [])
            }
        }
        .padding(3)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(BeetTheme.line(appearance)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session mode")
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
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(session.isRunning ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance).opacity(0.48))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 5) {
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Image(systemName: session.mode == "code" || !(session.workspacePath ?? "").isEmpty ? "folder.fill" : "bubble.left.and.bubble.right.fill")
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
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

struct RemoteSessionButtonStyle: ButtonStyle {
    @Environment(\.remoteAppearance) private var appearance

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? BeetTheme.surfaceStrong(appearance) : BeetTheme.surface(appearance).opacity(0.22),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.992 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

struct RemoteChromeButtonStyle: ButtonStyle {
    @Environment(\.remoteAppearance) private var appearance

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(BeetTheme.secondaryText(appearance))
            .background(BeetTheme.surfaceStrong(appearance), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
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
        VStack(spacing: 10) { Image(systemName: isSearching ? "magnifyingglass" : "rectangle.stack.badge.plus").font(.largeTitle).foregroundStyle(BeetTheme.accentBright); Text(isSearching ? "No matching sessions" : "No sessions yet").font(.headline); Text(isSearching ? "Try another title or project name." : "Tap + for a plain chat, or pick an optional bot. You can also continue a conversation from your Mac.").font(.subheadline).foregroundStyle(BeetTheme.secondaryText(appearance)).multilineTextAlignment(.center) }
            .padding(30).frame(maxWidth: .infinity).background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct AppearancePickerMenu: View {
    @AppStorage("remoteAppearance") private var appearance = RemoteAppearance.dark
    var body: some View { Picker("Appearance", selection: $appearance) { ForEach(RemoteAppearance.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) } } }
}

struct ConversationView: View {
    @Bindable var store: RemoteStore
    let sessionID: UUID
    @Environment(\.remoteAppearance) private var appearance
    @State private var draft = ""
    @State private var showSharing = false
    @State private var showComputers = false
    @State private var selectedModelID = ""
    @State private var dismissedErrorMessage: String?
    var body: some View {
        ZStack {
            RemoteBackdrop()
            if let detail = store.selectedSession, detail.id == sessionID {
                VStack(spacing: 0) {
                    ConversationStatus(
                        detail: detail,
                        models: store.startModels,
                        selectedModelID: $selectedModelID,
                        onStop: { Task { await store.stop() } })
                    if !store.isConnected {
                        RemoteReconnectBanner(store: store)
                    }
                    MessageTranscript(
                        detail: detail,
                        dismissedErrorMessage: dismissedErrorMessage,
                        onDismissError: { dismissedErrorMessage = detail.error?.message })
                    if let pending = detail.pending { PendingInteractionView(pending: pending) { value in Task { await store.resolvePending(value) } } }
                }
            } else { ProgressView("Opening conversation…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.navigationTitle(store.sessions.first(where: { $0.id == sessionID })?.title ?? "Conversation").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.92), for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showComputers = true } label: {
                        Image(systemName: "desktopcomputer.and.macbook")
                    }
                    .accessibilityLabel("Switch or add a Vamp Assistant computer")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Auto mode", isOn: $store.autoMode)
                        Toggle("Full Access", isOn: $store.fullAccess)
                        Divider()
                        Button { showSharing = true } label: {
                            Label("Share clipboard or files", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: store.fullAccess ? "lock.open.fill" : "ellipsis.circle")
                    }
                    .accessibilityLabel("Chat controls")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let detail = store.selectedSession, detail.id == sessionID {
                    VStack(spacing: 8) {
                        if let queued = detail.queued, !queued.isEmpty {
                            QueuedFollowUpsView(items: queued) { taskID in
                                Task { await store.cancelQueuedTask(taskID) }
                            }
                        }
                        RemoteComposer(
                            draft: $draft,
                            isRunning: detail.isRunning,
                            isReachable: store.isConnected,
                            onSend: { send() },
                            onQueue: { send(action: "queue") },
                            onSteer: { send(action: "steer") },
                            onStop: { Task { await store.stop() } })
                    }
                }
            }
            .task(id: sessionID) {
                dismissedErrorMessage = nil
                await store.select(sessionID: sessionID)
                await store.loadStartModels()
                if selectedModelID.isEmpty {
                    selectedModelID = store.startModels.matching(sessionModelID: store.selectedSession?.modelID ?? "")?.id ?? ""
                }
            }
            .onChange(of: selectedModelID) { old, new in
                guard !old.isEmpty, old != new else { return }
                dismissedErrorMessage = store.selectedSession?.error?.message ?? dismissedErrorMessage
            }
            .onChange(of: store.fullAccess) { _, enabled in
                guard enabled, store.selectedSession?.pending?.kind == "approval" else { return }
                Task { await store.resolvePending("approve") }
            }
            .sheet(isPresented: $showSharing) { RemoteShareSheet(store: store) }
            .sheet(isPresented: $showComputers) { ComputerSwitcherSheet(store: store) }
    }
    private func send(action: String? = nil) {
        let message = draft
        Task {
            if await store.send(message, modelID: selectedModelID.isEmpty ? nil : selectedModelID, action: action) {
                draft = ""
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}

struct ConversationStatus: View {
    let detail: RemoteSessionDetail
    let models: [RemoteStartModelOption]
    @Binding var selectedModelID: String
    var onStop: (() -> Void)? = nil
    @Environment(\.remoteAppearance) private var appearance

    private var selectedName: String {
        models.first(where: { $0.id == selectedModelID })?.name ?? detail.modelID
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(detail.isRunning ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)).frame(width: 7, height: 7)
            Text(detail.isRunning ? detail.phase.capitalized : "Ready").fontWeight(.semibold)
            Text("·")
            Text(detail.mode == "code" || !(detail.workspacePath ?? "").isEmpty ? "Code" : "Chat")
                .fontWeight(.semibold)
            if detail.mode == "code" || !(detail.workspacePath ?? "").isEmpty {
                Text("·")
                Text(detail.workspace).lineLimit(1)
            }
            Text("·")
            if models.isEmpty {
                Text(detail.modelID).lineLimit(1)
            } else {
                Menu {
                    ForEach(["local", "chatgpt", "api"], id: \.self) { source in
                        let group = models.filter { $0.source == source }
                        if !group.isEmpty {
                            Section(source == "chatgpt" ? "ChatGPT" : source.capitalized) {
                                ForEach(group) { model in
                                    Button {
                                        selectedModelID = model.id
                                    } label: {
                                        if selectedModelID == model.id {
                                            Label(model.name, systemImage: "checkmark")
                                        } else {
                                            Text(model.name)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(selectedName).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                }
                .disabled(detail.isRunning)
                .accessibilityLabel("Model, \(selectedName)")
            }
            Spacer(minLength: 8)
            if detail.isRunning {
                Button(action: { onStop?() }) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 26)
                        .background(Color(white: 0.24), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop the agent")
            } else {
                Label("\(detail.messages.count)", systemImage: "text.bubble")
            }
        }
        .font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
        .padding(.horizontal, 16).frame(minHeight: 34)
        .background(BeetTheme.surface(appearance).opacity(0.62))
    }
}

struct MessageTranscript: View {
    let detail: RemoteSessionDetail
    var dismissedErrorMessage: String? = nil
    var onDismissError: (() -> Void)? = nil
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 24) {
                    ForEach(detail.messages) { MessageBubble(message: $0) }
                    if detail.isRunning { StreamingBubble(text: detail.streamingText, phase: detail.phase) }
                    if let error = detail.error, error.message != dismissedErrorMessage {
                        RemoteChatErrorCard(error: error, onDismiss: onDismissError)
                    }
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
            HStack(alignment: .top) {
                Spacer(minLength: 46)
                VStack(alignment: .trailing, spacing: 6) {
                    Text("You")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BeetTheme.accentBright)
                    MarkdownText(message.content)
                        .multilineTextAlignment(.trailing)
                }
                .frame(maxWidth: 600, alignment: .trailing)
            }
        }
        else if message.role == "toolCall" || message.role == "toolResult" { ToolMessageCard(message: message) }
        else if message.role == "error" { EmptyView() }
        else if message.role == "notice" {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BeetTheme.accentBright)
                Text(message.content)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                Spacer(minLength: 4)
            }
        }
        else {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vamp Assistant").font(.caption.weight(.semibold)).foregroundStyle(BeetTheme.secondaryText(appearance))
                    MarkdownText(message.content)
                }
                Spacer(minLength: 4)
            }
        }
    }
}

struct RemoteChatErrorCard: View {
    let error: RemoteErrorPresentation
    var onDismiss: (() -> Void)? = nil
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Label(error.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(BeetTheme.accentBright)
                Spacer(minLength: 8)
                if let onDismiss {
                    Button("Dismiss", action: onDismiss)
                        .font(.caption.weight(.semibold))
                }
            }
            Text(error.message)
                .font(.subheadline)
                .lineSpacing(3)
                .textSelection(.enabled)
            Text("You can change the model or start a new chat. This failed chat will not be reopened automatically.")
                .font(.caption)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.32), lineWidth: 0.75)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(displayName, systemImage: message.role == "toolCall" ? "hammer" : "checkmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(BeetTheme.accentBright)
            if !displayContent.isEmpty {
                Text(displayContent).font(.caption.monospaced()).lineSpacing(3)
                    .textSelection(.enabled).lineLimit(12)
            }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(BeetTheme.surfaceStrong(appearance).opacity(0.64), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(BeetTheme.line(appearance).opacity(0.7), lineWidth: 0.75) }
    }

    private var displayName: String {
        let raw = message.toolName ?? "Tool activity"
        return raw.replacingOccurrences(of: "dynamic:", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }

    private var displayContent: String {
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "{}" { return "" }
        guard let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !array.isEmpty else { return message.content }
        let text = array.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.isEmpty ? message.content : text
    }
}

struct StreamingBubble: View {
    let text: String, phase: String
    @Environment(\.remoteAppearance) private var appearance
    var body: some View { HStack(alignment: .top, spacing: 11) { Color.clear.frame(width: 30, height: 30).accessibilityHidden(true); VStack(alignment: .leading, spacing: 8) { HStack(spacing: 7) { ProgressView().controlSize(.small); Text(phase.capitalized) }.font(.caption.weight(.semibold)).foregroundStyle(BeetTheme.accentBright); if text.isEmpty { Text("Vamp Assistant is working…").foregroundStyle(BeetTheme.secondaryText(appearance)) } else { MarkdownText(text) } }; Spacer(minLength: 4) } }
}

struct QueuedFollowUpsView: View {
    let items: [RemoteQueuedItem]
    let onCancel: (UUID) -> Void
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(spacing: 6) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(BeetTheme.accentBright)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label ?? "Queued")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(BeetTheme.accentBright)
                        Text(item.message)
                            .font(.caption)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button {
                        onCancel(item.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                    }
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                    .buttonStyle(RemotePressButtonStyle())
                    .accessibilityLabel("Remove queued follow-up")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(BeetTheme.line(appearance).opacity(0.9), lineWidth: 0.75)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }
}

struct RemoteComposer: View {
    @Binding var draft: String
    let isRunning: Bool
    var isReachable: Bool = true
    let onSend: () -> Void
    var onQueue: (() -> Void)? = nil
    var onSteer: (() -> Void)? = nil
    let onStop: () -> Void
    @Environment(\.remoteAppearance) private var appearance
    @FocusState private var isComposerFocused: Bool
    @State private var showCommands = false

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            Button { showCommands = true } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 40, height: 44)
            }
            .foregroundStyle(BeetTheme.accentBright)
            .buttonStyle(RemotePressButtonStyle())
            .disabled(!isReachable)
            .accessibilityLabel("Commands and context")
            TextField(placeholder, text: $draft, axis: .vertical)
                .font(.body).lineLimit(1...6).padding(.vertical, 12)
                .focused($isComposerFocused)
                .disabled(!isReachable)
            if isComposerFocused {
                Button {
                    isComposerFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .buttonStyle(RemotePressButtonStyle())
                .accessibilityLabel("Hide keyboard")
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
            if isRunning, hasDraft {
                Button {
                    if let onSteer { onSteer() } else { onSend() }
                } label: {
                    Text("Steer")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(BeetTheme.accentBright)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(BeetTheme.surfaceStrong(appearance), in: Capsule())
                }
                .buttonStyle(RemotePressButtonStyle())
                .accessibilityLabel("Steer this turn")
                .accessibilityHint("Redirects the current task instead of waiting")
            }
            Button(action: primaryAction) {
                Image(systemName: primarySymbol)
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(primaryColor, in: Circle())
            }
            .disabled(!isReachable || (!isRunning && !hasDraft))
            .buttonStyle(RemotePressButtonStyle())
            .accessibilityLabel(primaryLabel)
            .padding(.trailing, 4).padding(.vertical, 4)
        }
        .animation(.easeOut(duration: 0.16), value: isComposerFocused)
        .animation(.easeOut(duration: 0.16), value: isRunning && hasDraft)
        .frame(maxWidth: 720)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(BeetTheme.line(appearance).opacity(0.9), lineWidth: 0.75) }
        .shadow(color: .black.opacity(appearance == .light ? 0.10 : 0.22), radius: 18, y: 8)
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showCommands) {
            RemoteCommandPalette(draft: $draft) {
                showCommands = false
                isComposerFocused = true
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: draft) { _, value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/commands" {
                draft = ""
                showCommands = true
            }
        }
    }

    private var placeholder: String {
        if !isReachable { return "Waiting for Mac…" }
        if isRunning { return "Queue a follow-up or steer…" }
        return "Continue this coding task…"
    }

    private var primarySymbol: String {
        if isRunning, hasDraft { return "text.badge.plus" }
        if isRunning { return "stop.fill" }
        return "arrow.up"
    }

    private var primaryColor: Color {
        if isRunning, hasDraft { return BeetTheme.accent }
        if isRunning { return Color(white: 0.24) }
        return BeetTheme.accent
    }

    private var primaryLabel: String {
        if isRunning, hasDraft { return "Queue follow-up" }
        if isRunning { return "Stop the agent" }
        return "Send"
    }

    private func primaryAction() {
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
            showCommands = true
        } else {
            onSend()
        }
    }
}

private struct RemoteComposerCommand: Identifiable {
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

private struct RemoteCommandPalette: View {
    @Binding var draft: String
    let onChoose: () -> Void
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        NavigationStack {
            List {
                Section("Workspace") {
                    commandRows(Array(RemoteComposerCommand.commands.prefix(2)))
                }
                Section("Browser control") {
                    commandRows(Array(RemoteComposerCommand.commands.dropFirst(2).prefix(3)))
                }
                Section("Device") {
                    commandRows(Array(RemoteComposerCommand.commands.suffix(1)))
                }
            }
            .scrollContentBackground(.hidden)
            .background(BeetTheme.background(appearance))
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private func commandRows(_ commands: [RemoteComposerCommand]) -> some View {
        ForEach(commands) { command in
            Button {
                draft = command.prompt
                onChoose()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: command.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BeetTheme.accentBright)
                        .frame(width: 34, height: 34)
                        .background(BeetTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(command.title).font(.subheadline.weight(.semibold))
                        Text(command.detail).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

struct PendingInteractionView: View {
    let pending: RemotePendingInteraction
    let onResolve: (String) -> Void
    @Environment(\.remoteAppearance) private var appearance
    @State private var answer = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BeetTheme.accentBright)
                    .frame(width: 34, height: 34)
                    .background(BeetTheme.accent.opacity(0.13), in: Circle())
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

            Text(pending.summary ?? pending.content ?? "Vamp Assistant needs your input.")
                .font(.subheadline)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .lineSpacing(3)
                .textSelection(.enabled)

            if pending.kind == "question" {
                if let options = pending.options, !options.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(options, id: \.self) { option in
                            Button(option) { onResolve(option) }
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                TextField("Your answer", text: $answer)
                    .padding(11)
                    .background(BeetTheme.surfaceStrong(appearance), in: RoundedRectangle(cornerRadius: 11))
                Button("Send answer") { onResolve(answer) }
                    .buttonStyle(.borderedProminent)
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                ViewThatFits {
                    HStack(spacing: 9) { actionButtons }
                    VStack(spacing: 9) { actionButtons }
                }
            }
        }
        .padding(14)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(appearance == .light ? 0.08 : 0.2), radius: 14, y: 6)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var actionButtons: some View {
        Button(pending.kind == "plan" ? "Approve plan" : "Allow once") {
            onResolve("approve")
        }
        .buttonStyle(.borderedProminent)
        .tint(BeetTheme.accent)
        .frame(maxWidth: .infinity)
        if pending.kind == "approval" {
            Button("Decline", role: .destructive) { onResolve("decline") }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
    }

    private var title: String { switch pending.kind { case "question": "Question"; case "plan": "Plan ready"; default: "Approval needed" } }
    private var symbol: String { switch pending.kind { case "question": "questionmark.bubble"; case "plan": "list.bullet.clipboard"; default: "hand.raised.fill" } }
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
                Text("Files shared through Vamp Assistant appear in Downloads › BeetCode Remote on your Mac (legacy storage name).")
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
