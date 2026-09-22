import AppKit
import SwiftUI

// MARK: - Network tab

/// Endpoints this Mac exposes. These were cards four and five of a seven-card
/// General tab, where two server toggles with their own ports, tokens, and
/// running/not-running state sat below a font-size picker.
struct NetworkTab: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared
    @State private var apiTokenDraft = ""
    @State private var revealAPIToken = false
    @State private var apiTokenSaveMessage: String?

    var body: some View {
        TabScroll {
            InfoBanner(
                icon: "network",
                text: "Two separate services. The local API server listens on loopback only, so nothing off this Mac can reach it. Remote sessions listen on your local network and are reachable from anything that can route to this Mac on that network — a Tailscale connection is carried over the internet, so it is private to your tailnet rather than to this machine. Both start off until you turn them on, and both require the one-time pairing code.")

            SettingsCard(title: "Local API Server", icon: "network", footer: "Loopback-only OpenAI-compatible endpoint for the active model. Nothing outside this Mac can reach it.") {
                SettingToggle(label: "Enable local API server", isOn: $settings.apiServerEnabled)
                SettingRow(label: "Port") {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("1234", value: $settings.apiServerPort, format: .number.grouping(.never))
                            .vampField()
                            .frame(width: 90)
                            .monospacedDigit()
                        if let problem = Self.portProblem(settings.apiServerPort) {
                            Text(problem)
                                .font(.caption)
                                .foregroundStyle(Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                SettingRow(label: "Bearer token") {
                    HStack(spacing: Spacing.xs) {
                        Group {
                            if revealAPIToken {
                                TextField("Required", text: $apiTokenDraft)
                            } else {
                                SecureField("Required", text: $apiTokenDraft)
                            }
                        }
                        .vampField()
                        .font(.caption.monospaced())
                        .frame(minWidth: 180)
                        Button(revealAPIToken ? "Hide token" : "Reveal token",
                               systemImage: revealAPIToken ? "eye.slash" : "eye") {
                            revealAPIToken.toggle()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        Button("Save") {
                            let secured = settings.setAPIServerToken(apiTokenDraft)
                            apiTokenSaveMessage = secured
                                ? "Saved to Keychain."
                                : "Keychain unavailable; kept in local preferences."
                        }
                        .buttonStyle(LFCapsuleButtonStyle())
                        .controlSize(.small)
                    }
                }
                if let apiTokenSaveMessage {
                    Text(apiTokenSaveMessage)
                        .font(.caption)
                        .foregroundStyle(apiTokenSaveMessage.hasPrefix("Saved")
                            ? Theme.success : Theme.warning)
                }
                ServiceStateRow(
                    level: apiServerState.level,
                    state: apiServerState.word,
                    detail: apiServerState.detail,
                    monospacedDetail: appState.apiServerRunning,
                    actionTitle: "Copy curl example",
                    actionSystemImage: "doc.on.doc",
                    actionDisabled: !appState.apiServerRunning,
                    onAction: {
                        let token = settings.ensureAPIServerToken()
                        apiTokenDraft = token
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            """
                            curl \(appState.apiServerBaseURL)/v1/chat/completions \
                              -H 'Content-Type: application/json' \
                              -H 'Authorization: Bearer $BEETCODE_API_TOKEN' \
                              -d '{"model":"beetcode","messages":[{"role":"user","content":"Hello"}]}'
                            """,
                            forType: .string)
                    })
            }
            .onAppear {
                apiTokenDraft = settings.apiServerToken
            }

            SettingsCard(title: "Remote Vamp Assistant Sessions", icon: "iphone", footer: "Off by default. Uses port \(RemoteSessionPorts.defaultPort) so it can run beside Vamp Host (9475). LAN and Tailscale connections still require the one-time QR pairing code.") {
                SettingToggle(label: "Enable remote session access", isOn: $settings.remoteSessionEnabled)
                    .onChange(of: settings.remoteSessionEnabled) { _, enabled in
                        if enabled, !settings.remoteAccessConsentCompleted {
                            settings.remoteSessionEnabled = false
                            NotificationCenter.default.post(name: .openRemoteAccess, object: nil)
                        }
                    }
                SettingRow(label: "Port") {
                    TextField("\(RemoteSessionPorts.defaultPort)", value: $settings.remoteSessionPort, format: .number.grouping(.never))
                        .vampField()
                        .frame(width: 90)
                        .monospacedDigit()
                }
                SettingToggle(label: "Allow trusted local-network fallback", isOn: $settings.remoteSessionAllowLAN)
                if settings.remoteSessionAllowLAN {
                    Label("Use this only on a private Wi‑Fi network. Tailscale remains preferred when connected.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ServiceStateRow(
                    level: remoteState.level,
                    state: remoteState.word,
                    detail: remoteState.detail,
                    monospacedDetail: appState.remoteSessionRunning,
                    actionTitle: appState.remoteSessionRunning ? "Open pairing" : nil,
                    actionSystemImage: "iphone",
                    onAction: appState.remoteSessionRunning
                        ? { NotificationCenter.default.post(name: .openRemoteAccess, object: nil) }
                        : nil)
            }
        }
    }

    // MARK: Service state

    /// What each service is actually doing, derived from runtime state rather
    /// than from the preference toggle: "enabled" is what you asked for,
    /// "listening" is what is happening, and they are not the same thing.
    private var apiServerState: (level: ServiceStateRow.Level, word: String, detail: String) {
        if appState.apiServerRunning {
            return (.live, "Running", appState.apiServerBaseURL)
        }
        if let error = appState.apiServerError {
            return (.fault, "Failed to start", error)
        }
        if settings.apiServerEnabled {
            return (.idle, "Enabled, not listening",
                    "The endpoint answers nothing until the server is up on port \(settings.apiServerPort).")
        }
        return (.idle, "Off", "Turn the server on to serve the active model on loopback.")
    }

    private var remoteState: (level: ServiceStateRow.Level, word: String, detail: String) {
        if appState.remoteSessionRunning {
            return (.live, "Running", appState.remoteSessionURL ?? "Remote host ready")
        }
        if let error = appState.remoteSessionError {
            return (.fault, "Failed to start", error)
        }
        if settings.remoteSessionEnabled {
            return (.idle, "Enabled, not listening",
                    "Waiting for the remote host on port \(settings.remoteSessionPort).")
        }
        return (.idle, "Off", "Turn remote access on to pair a device.")
    }

    /// A port the OS can actually bind. Shown beside the field rather than in a
    /// banner, so the failure sits with the value that caused it.
    static func portProblem(_ port: Int) -> String? {
        guard port != 0 else { return nil }
        if port < 1024 {
            return "Ports below 1024 need root; pick 1024–65535."
        }
        if port > 65535 {
            return "Ports above 65535 cannot be bound."
        }
        return nil
    }
}

/// One service's runtime state: a lamp, the state in words, and the detail
/// that makes it actionable — the real listener, or the reason it is not up.
/// The lamp alone is not a status.
private struct ServiceStateRow: View {
    enum Level { case live, fault, idle }

    let level: Level
    let state: String
    let detail: String
    var monospacedDetail = false
    var actionTitle: String?
    var actionSystemImage = "bolt"
    var actionDisabled = false
    var onAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(state)
                    .font(.app(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(monospacedDetail ? .caption.monospaced() : .caption)
                    .foregroundStyle(level == .fault ? Theme.warning : Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(SelectableWhen(active: monospacedDetail))
            }
            Spacer(minLength: Spacing.sm)
            if let actionTitle, let onAction {
                Button(actionTitle, systemImage: actionSystemImage, action: onAction)
                    .buttonStyle(LFCapsuleButtonStyle())
                    .controlSize(.small)
                    .disabled(actionDisabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state). \(detail)")
    }

    private var tint: Color {
        switch level {
        case .live: Theme.success
        case .fault: Theme.warning
        case .idle: Theme.textTertiary
        }
    }
}

/// `textSelection` takes a concrete selectability type, so a boolean has to
/// choose the modifier rather than the argument.
private struct SelectableWhen: ViewModifier {
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}
