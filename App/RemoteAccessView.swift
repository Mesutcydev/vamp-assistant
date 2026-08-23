import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Host-side pairing surface for the Beetcode browser controller. The QR only
/// contains a short-lived pairing code; the browser exchanges it for a token
/// before it can read or continue any session.
struct RemoteAccessView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            if !settings.remoteSessionEnabled {
                disabledState
            } else if appState.remoteSessionRunning {
                runningState
            } else if let error = appState.remoteSessionError {
                errorState(error)
            } else {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Starting the remote session host…")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 560)
        .background(Theme.bg)
        .task {
            while !Task.isCancelled {
                appState.refreshRemoteSessionStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Theme.wash(Theme.accent))
                    .frame(width: 44, height: 44)
                Image(systemName: "iphone")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Image(systemName: "qrcode")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(3)
                    .background(Theme.surface, in: Circle())
                    .overlay(Circle().stroke(Theme.hairline, lineWidth: 0.5))
                    .offset(x: 9, y: 9)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote Beetcode sessions")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Scan once, then continue the same coding sessions from a phone or tablet.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Label("Done", systemImage: "xmark")
            }
            .buttonStyle(LFCapsuleButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Close remote sessions")
            .accessibilityLabel("Close remote sessions")
        }
    }

    private var disabledState: some View {
        return VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Remote access is off")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Beet Code will listen only when you turn this on. The browser surface is session-aware and never exposes the terminal CLI or the local model API.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                settings.remoteSessionEnabled = true
            } label: {
                Label("Enable remote access", systemImage: "power")
            }
            .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }

    private var runningState: some View {
        let expiresLabel = appState.remotePairingExpiresAt.map(Self.expiryText) ?? "soon"
        let browserLabel = appState.remotePairedClientCount == 1 ? "browser" : "browsers"
        return VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Label("Ready to pair", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.success)
                    .font(.headline)
                Spacer()
                Toggle("Enabled", isOn: $settings.remoteSessionEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            HStack(alignment: .top, spacing: Spacing.lg) {
                if let pairingURL = appState.remotePairingURL {
                    RemoteQRCodeView(value: pairingURL)
                        .frame(width: 210, height: 210)
                } else {
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(Theme.surfaceInset)
                        .frame(width: 210, height: 210)
                        .overlay { Text("No network address found")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(18) }
                }

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Scan with your phone camera")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    networkHint
                    Text("Pairing code")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(appState.remotePairingCode)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                    Text("Expires \(expiresLabel)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                    if let url = appState.remoteSessionURL {
                        Text(url)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Theme.hairline)
            VStack(alignment: .leading, spacing: 10) {
                Text("Sharing permissions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                Toggle(isOn: $settings.remoteClipboardSharingEnabled) {
                    Label("Clipboard exchange", systemImage: "doc.on.clipboard")
                }
                Toggle(isOn: $settings.remoteFileSharingEnabled) {
                    Label("File transfer", systemImage: "folder.badge.plus")
                }
            }
            .font(.callout)

            Divider().overlay(Theme.hairline)
            HStack(spacing: Spacing.sm) {
                Button {
                    copyPairingURL()
                } label: {
                    Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link")
                }
                .buttonStyle(LFCapsuleButtonStyle())
                .disabled(appState.remotePairingURL == nil)
                Button("New code", systemImage: "arrow.clockwise") {
                    appState.rotateRemotePairingCode()
                }
                .buttonStyle(LFCapsuleButtonStyle())
                Spacer()
                Button("Revoke all browsers", role: .destructive) {
                    appState.revokeRemoteClients()
                }
                .buttonStyle(LFCapsuleButtonStyle(tone: .destructive))
            }
            Text("\(appState.remotePairedClientCount) paired \(browserLabel)")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }

    @ViewBuilder
    private var networkHint: some View {
        Group {
            switch appState.remoteNetworkKind {
            case .tailscale:
                Label("Connected through Tailscale. Traffic stays on your tailnet.", systemImage: "lock.shield.fill")
                    .foregroundStyle(Theme.success)
            case .localNetwork:
                Label("Local-network fallback is enabled. Use only on trusted private Wi‑Fi.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            case nil:
                Label("Waiting for a reachable network address…", systemImage: "network.slash")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func errorState(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label("Remote host could not start", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .font(.headline)
            Text(error)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
            Button("Retry") { appState.retryRemoteSessionHost() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }

    private func copyPairingURL() {
        guard let value = appState.remotePairingURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private static func expiryText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// One-time capability consent shown before the remote listener is enabled.
/// The user can keep session control while independently declining clipboard
/// or file access; the host enforces both choices on every request.
struct RemoteAccessConsentView: View {
    let onCancel: () -> Void
    let onAllow: (_ clipboard: Bool, _ files: Bool) -> Void

    @State private var allowClipboard = true
    @State private var allowFiles = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 46, height: 46)
                    .background(Theme.wash(Theme.accent), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Allow Remote Sessions?")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Paired devices can continue your Beet Code sessions while this Mac and the remote host are on.")
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
                    detail: "Share files up to 20 MB through BeetCode Remote Downloads.",
                    trailing: AnyView(Toggle("", isOn: $allowFiles).labelsHidden()))
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.75))

            Label("Only paired devices on your Tailscale network are accepted. You can change or revoke access later.", systemImage: "network.badge.shield.half.filled")
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
        .background(Theme.bg)
    }

    private func capabilityRow(
        icon: String,
        title: String,
        detail: String,
        trailing: AnyView
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.wash(Theme.accent), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                    .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: value) { image = Self.makeImage(from: value) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Beet Code remote pairing QR code")
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
