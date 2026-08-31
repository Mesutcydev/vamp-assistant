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
                text: "Both servers are off by default and stay off until you turn them on. Nothing here reaches the internet: the API server is loopback-only, and remote sessions require a one-time pairing code over your LAN or Tailscale.")

            SettingsCard(title: "Local API Server", icon: "network", footer: "Loopback-only OpenAI-compatible endpoint for the active model. Nothing outside this Mac can reach it.") {
                SettingToggle(label: "Enable local API server", isOn: $settings.apiServerEnabled)
                SettingRow(label: "Port") {
                    TextField("1234", value: $settings.apiServerPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .monospacedDigit()
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
                        .textFieldStyle(.roundedBorder)
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
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                if let apiTokenSaveMessage {
                    Text(apiTokenSaveMessage)
                        .font(.caption)
                        .foregroundStyle(apiTokenSaveMessage.hasPrefix("Saved")
                            ? Theme.success : Theme.warning)
                }
                HStack(spacing: Spacing.sm) {
                    Circle()
                        .fill(appState.apiServerRunning ? Theme.success : Theme.textTertiary)
                        .frame(width: 8, height: 8)
                    if appState.apiServerRunning {
                        Text("Serving at \(appState.apiServerBaseURL)")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    } else if let error = appState.apiServerError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    } else {
                        Text("Not running")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Copy curl example") {
                        let token = settings.ensureAPIServerToken()
                        apiTokenDraft = token
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            """
                            curl \(appState.apiServerBaseURL)/v1/chat/completions \\
                              -H 'Content-Type: application/json' \\
                              -H 'Authorization: Bearer \(token)' \\
                              -d '{"model":"beetcode","messages":[{"role":"user","content":"Hello"}]}'
                            """,
                            forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!appState.apiServerRunning)
                }
            }
            .onAppear {
                apiTokenDraft = settings.apiServerToken
            }

            SettingsCard(title: "Remote Vamp Assistant Sessions", icon: "iphone", footer: "Off by default. Uses port \(RemoteSessionPorts.defaultPort) so it can run beside Vamp Host (9475). LAN and Tailscale connections still require the one-time QR pairing code.") {
                SettingToggle(label: "Enable remote session access", isOn: $settings.remoteSessionEnabled)
                SettingRow(label: "Port") {
                    TextField("\(RemoteSessionPorts.defaultPort)", value: $settings.remoteSessionPort, format: .number)
                        .textFieldStyle(.roundedBorder)
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
                HStack(spacing: Spacing.sm) {
                    Circle()
                        .fill(appState.remoteSessionRunning ? Theme.success : Theme.textTertiary)
                        .frame(width: 8, height: 8)
                    if appState.remoteSessionRunning {
                        Text(appState.remoteSessionURL ?? "Remote host ready")
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let error = appState.remoteSessionError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                            .lineLimit(2)
                    } else {
                        Text("Not running")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if appState.remoteSessionRunning {
                        Button("Open pairing", systemImage: "iphone") {
                            NotificationCenter.default.post(name: .openRemoteAccess, object: nil)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}
