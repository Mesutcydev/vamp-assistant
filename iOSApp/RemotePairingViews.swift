import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
                            requiresPairing: store.requiresPairing,
                            isConnecting: store.isConnecting, onScan: { showScanner = true },
                            onReconnect: {
                                if store.requiresPairing {
                                    address = store.savedMacAddress ?? address
                                    showManual = true
                                    focusedField = .code
                                } else {
                                    Task { await store.connectSaved() }
                                }
                            },
                            onForget: { store.forgetSavedMac() },
                            onConnect: { Task { await store.connect(address: address, code: code) } })
                        PairingAssurances()
                        RemoteAppVersionFooter(
                            version: RemoteAppVersion.current.version,
                            build: RemoteAppVersion.current.build)
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
            .onAppear {
                guard store.requiresPairing else { return }
                address = store.savedMacAddress ?? address
                showManual = true
            }
        }
    }
    private var errorBinding: Binding<Bool> { Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }) }
}

struct PairingHero: View {
    @Environment(\.remoteAppearance) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Text("Connect to your Mac")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        } else {
            VStack(spacing: 15) {
                Color.clear.frame(width: 76, height: 76).accessibilityHidden(true)
                VStack(spacing: 7) {
                    Text("Vamp Assistant")
                        .font(.largeTitle.weight(.bold))
                        .fontDesign(.serif)
                        .minimumScaleFactor(0.7)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your Mac. In your pocket.").font(.headline.weight(.semibold)).foregroundStyle(BeetTheme.accentBright)
                    Text("Continue Assistant, Code, and specialist bot sessions securely from iPhone or iPad.")
                        .font(.body).foregroundStyle(BeetTheme.secondaryText(appearance)).multilineTextAlignment(.center).lineSpacing(2)
                }
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
    let requiresPairing: Bool
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
                    requiresPairing: requiresPairing,
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
    let requiresPairing: Bool
    let isConnecting: Bool
    let onReconnect: () -> Void
    let onForget: () -> Void
    @State private var showForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(BeetTheme.surfaceStrong(appearance)).frame(width: 38, height: 38)
                    Image(systemName: "desktopcomputer").font(.subheadline.weight(.semibold)).foregroundStyle(BeetTheme.accentBright)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(requiresPairing ? "Pair this Mac again" : "Your paired Mac")
                        .font(.subheadline.weight(.semibold))
                    Text(address).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance)).lineLimit(1)
                }
                Spacer()
                Menu {
                    Button("Forget this Mac", systemImage: "trash", role: .destructive) { showForget = true }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 36, height: 36).hitTarget()
                }
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .accessibilityLabel("Paired Mac options")
            }
            Button(action: onReconnect) {
                HStack(spacing: 8) {
                    if isConnecting { ProgressView().tint(.white).controlSize(.small) }
                    Label(
                        isConnecting ? "Looking for your Mac…" : (requiresPairing ? "Enter new pairing code" : "Connect again"),
                        systemImage: requiresPairing ? "key.fill" : "bolt.horizontal.circle.fill")
                }
                .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(RemotePrimaryButtonStyle())
            .disabled(isConnecting)
        }
        .padding(14)
        .remoteGlass(appearance, radius: 17)
        .confirmationDialog(
            "Forget this Mac?",
            isPresented: $showForget,
            titleVisibility: .visible) {
                Button("Forget this Mac", role: .destructive, action: onForget)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The saved address and access token are deleted. You will need the pairing code from your Mac to connect again.")
            }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let items = [("lock.shield.fill", "Private", "Direct to your Mac"), ("checkmark.shield.fill", "In control", "You choose access"), ("bolt.shield.fill", "No cloud relay", "LAN or Tailscale")]
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 18))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout {
            ForEach(items, id: \.1) { item in
                VStack(spacing: 6) {
                    // ponytail: fixed box. Glyph heights differ, and under .top a
                    // short one pulled its whole column ~5pt above the others.
                    Image(systemName: item.0)
                        .font(.system(size: 15))
                        .frame(height: 18)
                        .foregroundStyle(BeetTheme.accentBright)
                    Text(item.1).font(.caption.weight(.bold))
                    Text(item.2).font(.caption2).foregroundStyle(BeetTheme.secondaryText(appearance)).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white)
            .background(BeetTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.975 : 1).opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct RemoteSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.remoteAppearance) private var appearance
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(BeetTheme.secondaryText(appearance))
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(BeetTheme.surfaceStrong(appearance).opacity(0.2), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(BeetTheme.line(appearance)) }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1).animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ComputerSwitcherSheet: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var showPairing = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ComputerSwitcherIntro()
                        Button { showDiagnostics = true } label: {
                            Label("Connection details", systemImage: "network")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
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
            .sheet(isPresented: $showDiagnostics) { RemoteDiagnosticsView(store: store) }
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
                            requiresPairing: false,
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
                        .accessibilityHidden(true)
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
            .background(.thinMaterial)
            .background(BeetTheme.surface(appearance).opacity(0.3))
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
    @State private var showRemove = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 13) {
                    Image(systemName: "macmini")
                        .accessibilityHidden(true)
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
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(RemotePressButtonStyle())
            Menu {
                Button("Remove computer", systemImage: "trash", role: .destructive) { showRemove = true }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(BeetTheme.secondaryText(appearance))
            .accessibilityLabel("Options for \(computer.name)")
        }
        .padding(14)
        .remoteGlass(appearance, radius: 19)
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 19)
                    .stroke(BeetTheme.accentBright.opacity(0.75), lineWidth: 1.25)
            }
        }
        .confirmationDialog(
            "Remove \(computer.name)?",
            isPresented: $showRemove,
            titleVisibility: .visible) {
                Button("Remove computer", role: .destructive, action: onRemove)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its saved access token is deleted. You will need the pairing code from that Mac to add it again.")
            }
    }
}
