import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Device access reflects the actual host, with pairing separated from service
/// status and sharing. The wire protocol and trust store stay unchanged.
struct RemoteAccessView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var permissions = MacPermissionState.shared
    var presentedAsSheet: Bool = true
    @State private var copied = false
    @State private var showsConsent = false
    @State private var showsPairing = false
    private var preview: Bool { DesignPreviewScreen.fromLaunchArguments() == .devices }
    private var running: Bool { preview || appState.remoteSessionRunning }
    private var enabled: Bool { preview || settings.remoteSessionEnabled }
    private var clientCount: Int { preview ? 2 : appState.remotePairedClientCount }
    private var pairingCode: String { preview ? "482 716" : appState.remotePairingCode }
    private var pairingURL: String? { preview ? "https://example.com/pair?code=482716" : appState.remotePairingURL }
    private var expiresAt: Date? { preview ? Date().addingTimeInterval(240) : appState.remotePairingExpiresAt }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Devices").font(.system(size: 24, weight: .semibold))
                            Text("Continue your conversations from a paired phone, tablet, or browser.")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 8)
                        if presentedAsSheet { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
                    }
                    serviceCard
                    if running {
                        SettingsCard(title: "Pair a device", icon: "qrcode") {
                            DisclosureGroup("Show pairing code", isExpanded: $showsPairing) {
                                pairingSection(narrow: geometry.size.width < 680).padding(.top, 12)
                            }
                        }
                    }
                    SettingsCard(title: "Sharing", icon: "square.and.arrow.up") {
                        Toggle("Clipboard exchange", isOn: $settings.remoteClipboardSharingEnabled)
                        Toggle("File transfer", isOn: $settings.remoteFileSharingEnabled)
                        Toggle("Mac control from iPhone", isOn: $settings.remoteMacControlEnabled)
                            .onChange(of: settings.remoteMacControlEnabled) { _, value in
                                if !value { appState.remoteSessionHost.disableMacControl() }
                                else {
                                    if !permissions.accessibilityGranted { permissions.requestAccessibility() }
                                    if !permissions.screenRecordingGranted { permissions.requestScreenRecording() }
                                }
                            }
                        Toggle("Remote unlock from iPhone", isOn: $settings.remoteMacUnlockEnabled)
                            .disabled(!settings.remoteMacControlEnabled)
                        if settings.remoteMacControlEnabled {
                            Text("Unlock works through Tailscale while this Mac is locked. Your login password is never stored or logged.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                    }.toggleStyle(.switch).disabled(preview)
                    SettingsCard(title: "Mac permissions", icon: "hand.raised") {
                        MacPermissionRows()
                        Button("Refresh permission status", systemImage: "arrow.clockwise") { permissions.refresh() }
                            .buttonStyle(.borderless)
                    }
                    if clientCount > 0 {
                        SettingsCard(title: "Paired clients", icon: "laptopcomputer.and.iphone") {
                            SettingRow(label: "Trusted clients", value: "Pairing is required on every new device") {
                                Text("\(clientCount)").font(.system(size: 20, weight: .semibold))
                            }
                            Button("Revoke all clients…", role: .destructive) { confirmRevokeAll() }.disabled(preview)
                        }
                    }
                }
                .frame(width: max(0, min(820, geometry.size.width - 48)), alignment: .leading)
                .padding(.vertical, 32).frame(maxWidth: .infinity)
            }
        }
        .background(Theme.workspaceCanvas).foregroundStyle(Theme.textPrimary)
        .font(.system(size: 13))
        .frame(minWidth: presentedAsSheet ? 420 : 0, minHeight: presentedAsSheet ? 560 : 0)
        .sheet(isPresented: $showsConsent) {
            RemoteAccessConsentView(onCancel: { showsConsent = false }, onAllow: { clipboard, files in
                settings.remoteAccessConsentCompleted = true
                settings.remoteClipboardSharingEnabled = clipboard
                settings.remoteFileSharingEnabled = files
                settings.remoteSessionEnabled = true
                showsConsent = false
                showsPairing = true
            })
        }
        .task {
            guard !preview else { showsPairing = true; return }
            permissions.refresh()
            while !Task.isCancelled {
                appState.refreshRemoteSessionStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var serviceCard: some View {
        SettingsCard(title: "Remote access", icon: "network") {
            HStack(spacing: 12) {
                Label(running ? "Running" : enabled ? "Starting" : "Off",
                      systemImage: running ? "checkmark.circle" : "circle")
                    .foregroundStyle(running ? Theme.success : Theme.textSecondary)
                Spacer()
                if enabled {
                    Button("Turn off") { settings.remoteSessionEnabled = false }.disabled(preview)
                } else {
                    Button("Enable remote access") {
                        if settings.remoteAccessConsentCompleted { settings.remoteSessionEnabled = true; showsPairing = true }
                        else { showsConsent = true }
                    }.buttonStyle(.borderedProminent)
                }
            }
            if let error = appState.remoteSessionError, enabled && !running {
                Text(error).foregroundStyle(Theme.warning).textSelection(.enabled)
                Button("Retry") { appState.retryRemoteSessionHost() }
            } else if running {
                Text("\(clientCount) paired \(clientCount == 1 ? "client" : "clients")")
                    .foregroundStyle(Theme.textSecondary)
                networkHint
                if let url = appState.remoteSessionURL { Text(url).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
            } else {
                Text("Enable access when you want a paired device to reach this Mac.").foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func pairingSection(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if narrow {
                pairingCodeSection
                qrCode
            } else {
                HStack(alignment: .top, spacing: 24) { qrCode; pairingCodeSection }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { pairingActions }
                VStack(alignment: .leading, spacing: 8) { pairingActions }
            }
        }
    }
    private var qrCode: some View {
        Group {
            if let pairingURL { RemoteQRCodeView(value: pairingURL).frame(width: 160, height: 160) }
            else { Label("Waiting for a network address", systemImage: "network.slash").foregroundStyle(Theme.textSecondary) }
        }
    }
    private var pairingCodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scan with your phone camera").font(.system(size: 13, weight: .semibold))
            Text(pairingCode.isEmpty ? "Generating…" : pairingCode).font(.system(size: 28, weight: .semibold, design: .monospaced))
                .textSelection(.enabled).accessibilityLabel("Pairing code: \(pairingCode)")
            if preview { Text("Expires in 4 minutes").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
            else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let expiresAt {
                        Text(expiresAt <= context.date ? "Code expired — generate a new code" : "Expires in \(max(0, Int(expiresAt.timeIntervalSince(context.date)))) seconds")
                            .font(.system(size: 12)).foregroundStyle(expiresAt <= context.date ? Theme.warning : Theme.textSecondary)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var pairingActions: some View {
        Button(copied ? "Copied" : "Copy pairing link", systemImage: "link") {
            guard let pairingURL else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pairingURL, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
        }.disabled(pairingURL == nil || preview || (expiresAt.map { $0 <= Date() } ?? true))
        Button("New code", systemImage: "arrow.clockwise") { appState.rotateRemotePairingCode() }.disabled(preview)
    }
    @ViewBuilder private var networkHint: some View {
        if preview || appState.remoteNetworkKind == .tailscale {
            Label("Connected through Tailscale", systemImage: "lock.shield").foregroundStyle(Theme.textSecondary)
        } else if appState.remoteNetworkKind == .localNetwork {
            Label("Local network · use trusted private Wi-Fi", systemImage: "wifi").foregroundStyle(Theme.warning)
        } else { Label("Waiting for a network address", systemImage: "network.slash").foregroundStyle(Theme.textSecondary) }
    }
    private func confirmRevokeAll() {
        guard clientCount > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Revoke all paired clients?"
        alert.informativeText = "Every paired device loses access immediately and must pair again with a new code."
        alert.addButton(withTitle: "Revoke"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { appState.revokeRemoteClients() }
    }
}

/// One-time capability consent shown before the remote listener is enabled.
/// The user can keep session control while independently declining clipboard
/// or file access; the host enforces both choices on every request.
struct RemoteAccessConsentView: View {
    let onCancel: () -> Void
    let onAllow: (_ clipboard: Bool, _ files: Bool) -> Void

    @State private var allowClipboard = false
    @State private var allowFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.app(size: 22, weight: .semibold ))
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 46, height: 46)
                    .background(Theme.wash(Theme.accent), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Allow Remote Sessions?")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Paired devices can continue your Vamp Assistant sessions while this Mac and the remote host are on.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                capabilityRow(
                    icon: "bubble.left.and.bubble.right.fill",
                    title: "Control sessions",
                    detail: "Read chats, send prompts, and approve agent actions.",
                    trailing: AnyView(Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)))
                Divider().padding(.leading, 50)
                capabilityRow(
                    icon: "doc.on.clipboard",
                    title: "Clipboard exchange",
                    detail: "Copy text between this Mac and a paired device.",
                    trailing: AnyView(Toggle("", isOn: $allowClipboard).labelsHidden()))
                Divider().padding(.leading, 50)
                capabilityRow(
                    icon: "folder.badge.plus",
                    title: "File transfer",
                    detail: "Share files up to 20 MB through Vamp Assistant Remote Downloads.",
                    trailing: AnyView(Toggle("", isOn: $allowFiles).labelsHidden()))
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.75))

            Label("Only paired devices on an allowed LAN or Tailscale network are accepted. You can change or revoke access later.", systemImage: "network.badge.shield.half.filled")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Not now", action: onCancel)
                    .buttonStyle(LFCapsuleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    onAllow(allowClipboard, allowFiles)
                } label: {
                    Label("Allow Remote Sessions", systemImage: "checkmark")
                }
                .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(.ultraThinMaterial)
    }

    private func capabilityRow(
        icon: String,
        title: String,
        detail: String,
        trailing: AnyView
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.app(size: 15, weight: .semibold ))
                .foregroundStyle(Theme.accentText)
                .frame(width: 36, height: 36)
                .background(Theme.wash(Theme.accent), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(14)
    }
}

private struct RemoteQRCodeView: View {
    let value: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(12)
                    // Intentionally NOT themed: a QR code needs a white quiet
                    // zone to scan. Theming this to the dark surface would make
                    // the code unreadable to the phone's camera.
                    .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: value) { image = Self.makeImage(from: value) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vamp Assistant remote pairing QR code")
    }

    private static let context = CIContext()

    private static func makeImage(from value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        let scale = 640 / max(extent.width, extent.height)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
