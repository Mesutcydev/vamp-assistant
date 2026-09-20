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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedField: PairingField?
    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    let wide = (horizontalSizeClass == .regular || verticalSizeClass == .compact)
                        && !dynamicTypeSize.isAccessibilitySize
                    let layout = wide
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: 28))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
                    VStack(spacing: 20) {
                    layout {
                        PairingHero()
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                        PairingAssurances()
                        RemoteAppVersionFooter(
                            version: RemoteAppVersion.current.version,
                            build: RemoteAppVersion.current.build)
                    }.frame(maxWidth: wide ? 900 : 560).padding(20).frame(maxWidth: .infinity)
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
            // Matches the hero heading below it — two phrasings for one screen
            // ("Connect to Mac" / "Connect your Mac") read as two destinations,
            // and VoiceOver announced both.
            .navigationTitle("Connect your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .remoteNavigationChrome()
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
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    pairingGlyph
                    Text("VAMP ASSISTANT")
                        .font(.caption.weight(.semibold))
                        .tracking(1.35)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    remoteBadge
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        pairingGlyph
                        Spacer(minLength: 12)
                        remoteBadge
                    }
                    Text("VAMP\nASSISTANT")
                        .font(.headline.weight(.semibold))
                        .tracking(1.1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(RemoteInstrument.seam).frame(height: 0.75)
            }
            Text("Connect your Mac")
                .font(RemoteInstrument.TypeStyle.title)
                .tracking(-0.5)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Bring your conversations, approvals, and Mac controls to this device.")
                .font(.body)
                .foregroundStyle(RemoteInstrument.secondaryInk)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                Text("01").font(RemoteInstrument.TypeStyle.metadata).foregroundStyle(RemoteInstrument.orange)
                Text("Open Remote Sessions on your Mac").font(.subheadline)
            }
            HStack(alignment: .top, spacing: 10) {
                Text("02").font(RemoteInstrument.TypeStyle.metadata).foregroundStyle(RemoteInstrument.orange)
                Text("Scan the code with this device").font(.subheadline)
            }
        }
        .foregroundStyle(RemoteInstrument.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pairingGlyph: some View {
        Image(systemName: "desktopcomputer")
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(RemoteInstrument.darkInsert, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    private var remoteBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(RemoteInstrument.orange).frame(width: 4, height: 4).accessibilityHidden(true)
            Text("REMOTE").font(.caption2.monospaced())
        }
        .foregroundStyle(RemoteInstrument.secondaryInk)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct PairingActions: View {
    @Environment(\.remoteAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    Text("or pair another Mac").font(.caption).foregroundStyle(RemoteInstrument.secondaryInk)
                    Capsule().fill(BeetTheme.line(appearance)).frame(height: 1)
                }
                .padding(.vertical, 2)
            }
            VStack(alignment: .leading, spacing: 12) {
                VampMicroLabel(title: "PAIR WITH YOUR MAC")
            Button(action: onScan) {
                HStack(spacing: 12) {
                    Image(systemName: "qrcode.viewfinder").font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scan pairing code").font(.headline)
                        Text("Use the code shown on your Mac").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                }.padding(.vertical, 14)
            }
                .buttonStyle(RemotePrimaryButtonStyle())
            }
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
                    .foregroundStyle(RemoteInstrument.secondaryInk).frame(minHeight: 44)
            }.tint(RemoteInstrument.secondaryInk)
            // Sits after both pairing paths: Tailscale is a prerequisite you
            // may need before either works, not a third way to pair. It used to
            // split scan and manual entry with equal visual weight.
            Button { TailscaleLauncher.open() } label: {
                Label("Open Tailscale", systemImage: "network")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(RemoteSecondaryButtonStyle())
            .accessibilityHint("Opens the Tailscale app, or its App Store page if it is not installed.")
        }
        .padding(RemoteInstrument.Space.page)
        .remoteFaceplate()
        .animation(reduceMotion ? nil : RemoteInstrument.motion, value: showManual)
        .foregroundStyle(RemoteInstrument.ink)

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
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: RemoteInstrument.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: RemoteInstrument.controlRadius, style: .continuous)
                .stroke(BeetTheme.line(appearance), lineWidth: 0.75)
        }
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
            Text(title.uppercased()).font(.system(.caption2, design: .monospaced, weight: .medium)).tracking(0.8).foregroundStyle(BeetTheme.secondaryText(appearance))
            TextField(placeholder, text: $text,
                      prompt: Text(placeholder).foregroundStyle(BeetTheme.secondaryText(appearance)))
                .textContentType(field == .code ? .oneTimeCode : .URL)
                .keyboardType(field == .code ? .numberPad : .URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focusedField, equals: field)
                .accessibilityLabel(title)
                .onChange(of: text) { _, value in
                    guard field == .code else { return }
                    let digits = String(value.filter(\.isNumber).prefix(6))
                    if digits != text { text = digits }
                    // ponytail: a numberPad has no return key, so .submitLabel/
                    // .onSubmit never fire on-device and the Connect button sits
                    // behind the keyboard. Drop focus once the code is complete.
                    if digits.count == 6 { focusedField.wrappedValue = nil }
                }
                .padding(.horizontal, 14).frame(minHeight: 50)
                .background(BeetTheme.readingSurface(appearance), in: RoundedRectangle(cornerRadius: RemoteInstrument.controlRadius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: RemoteInstrument.controlRadius).stroke(BeetTheme.line(appearance)) }
        }
    }
}

struct PairingAssurances: View {
    var body: some View {
        Label("A direct, private connection over your local network or Tailscale.", systemImage: "lock.shield")
            .font(.footnote)
            .foregroundStyle(RemoteInstrument.secondaryInk)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
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
    var alignment: Alignment = .center
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 44, alignment: alignment)
            .foregroundStyle(.white)
            .modifier(RemoteKeySurface(isPressed: configuration.isPressed, prominent: true))
    }
}

struct RemoteSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .foregroundStyle(configuration.role == .destructive ? RemoteInstrument.danger : RemoteInstrument.ink)
            .modifier(RemoteKeySurface(isPressed: configuration.isPressed))
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
            .remoteNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }.vampUtilityAction()
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
            .remoteNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }.vampUtilityAction()
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

    var body: some View {
        Button {
            Task { await store.connectSaved() }
        } label: {
            RemoteNoticeLabel(title: store.isConnecting ? "Reconnecting to Mac" : "Mac unreachable",
                detail: store.connectionSubtitle, actionTitle: store.isConnecting ? "Connecting…" : "Retry",
                symbol: "wifi.exclamationmark", isWorking: store.isConnecting)
        }
        .buttonStyle(.plain)
        .disabled(store.isConnecting)
        .accessibilityLabel(store.isConnecting ? "Reconnecting to Mac" : "Mac unreachable. Retry connection.")
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
                .background(BeetTheme.surfaceStrong(appearance), in: RoundedRectangle(cornerRadius: RemoteInstrument.controlRadius))
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
                                    in: RoundedRectangle(cornerRadius: RemoteInstrument.controlRadius))
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
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .background(isActive ? RemoteInstrument.recess : Color.clear)
        .overlay(alignment: .bottom) { VampHairline() }
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
