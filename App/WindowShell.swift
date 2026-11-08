import AppKit
import SwiftUI

enum ShellDestination: Hashable, Identifiable {
    case conversations, devices, settings(SettingsView.Tab)
    var id: String {
        switch self { case .conversations: "chats"; case .devices: "devices"; case .settings: "settings" }
    }
}

struct ShellSidebar: View {
    @Binding var destination: ShellDestination
    @Binding var historySearch: String
    var searchFocusRevision: Int
    @Binding var showRemoteAccess: Bool
    var onSettings: () -> Void
    var onOpenInNewWindow: (UUID) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.accentText)
                Text("Vamp Assistant").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).frame(height: 48)
            VStack(spacing: 4) {
                WorkspaceNavigationRow(title: "Chats", symbol: "bubble.left.and.bubble.right",
                    selected: destination == .conversations) { destination = .conversations }
                WorkspaceNavigationRow(title: "Devices", symbol: "iphone",
                    selected: destination == .devices) { destination = .devices }
            }.padding(.horizontal, 8)
            Divider().padding(12)
            switch destination {
            case .conversations:
                VampSearchField(placeholder: "Search chats", text: $historySearch,
                                focus: $searchFocused, identifier: "conversation-search")
                    .padding(.horizontal, 12).padding(.bottom, 8)
                SidebarView(showRemoteAccess: $showRemoteAccess, onClose: {},
                    historySearch: $historySearch, onOpenInNewWindow: onOpenInNewWindow)
            case .devices:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Continue anywhere").font(.system(size: 12, weight: .semibold))
                    Text("Pair your phone or tablet to access this Mac’s conversations and tools.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }.padding(.horizontal, 18)
                Spacer(minLength: 0)
            case .settings(let current):
                VStack(spacing: 4) {
                    ForEach(SettingsView.Tab.navigationTabs) { tab in
                        WorkspaceNavigationRow(title: tab.rawValue, symbol: tab.icon,
                            selected: current == tab) { destination = .settings(tab) }
                    }
                }.padding(.horizontal, 8)
                Spacer(minLength: 0)
            }
            WorkspaceNavigationRow(title: "Settings", symbol: "gearshape",
                selected: isSettings) { onSettings() }
                .padding(8)
        }
        .background(Theme.navigationSurface)
        .foregroundStyle(Theme.textPrimary)
        .onChange(of: searchFocusRevision) { _, _ in searchFocused = true }
    }
    private var isSettings: Bool { if case .settings = destination { true } else { false } }
}

struct WorkspaceNavigationRow: View {
    let title: String
    let symbol: String
    var selected = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 20)
                    .foregroundStyle(selected ? Theme.accentText : Theme.textSecondary)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(minHeight: 34)
            .contentShape(Rectangle())
            .background(selected ? Theme.accentSoft : hovering ? Theme.navigationRowHover : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Inspector

/// The window's detail panel: what the frame's lamp column and vertical fader
/// used to show, in readable native rows. Every value is real state, and every
/// row says what it means in words — a green dot alone cannot distinguish
/// "available" from "you granted permission".
struct ShellInspector: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AgentSessionController
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Session") {
                statusRow(title: "Assistant",
                          on: appState.isModelReady || controller.isRunning,
                          detail: controller.isRunning
                          ? "Working"
                          : (appState.isModelReady ? "Ready" : "No model loaded"))
                statusRow(title: "Web search",
                          on: TinyFishSearchCredentialStore.isConfigured,
                          detail: TinyFishSearchCredentialStore.isConfigured
                          ? "API key configured"
                          : "No API key")
                statusRow(title: "Files",
                          on: controller.workspaceURL != nil,
                          detail: controller.workspaceURL?.lastPathComponent ?? "No project open")
                statusRow(title: "Mac control",
                          on: settings.computerControlEnabled,
                          detail: settings.computerControlEnabled
                          ? "Enabled in settings"
                          : "Off")
            }

            Section("Model") {
                InspectorReasoningPicker()
            }
        }
        .formStyle(.grouped)
        .accessibilityLabel("Session inspector")
    }

    /// State in words first, colour second: the dot repeats the text, it never
    /// carries the meaning alone.
    private func statusRow(title: String, on: Bool, detail: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Circle()
                    .fill(on ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(detail)")
    }
}

/// The control the frame drew as a vertical fader labelled FIXED. It is not a
/// scalar: it picks among the reasoning efforts the active model advertises,
/// with Automatic as the default stop — so it is a picker, and it is disabled
/// (not mislabelled) when a model advertises none.
struct InspectorReasoningPicker: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var account = CodexAccountStore.shared
    @State private var revision = 0

    private var accountModel: CodexModelProfile? {
        guard appState.isCodexActive, let id = appState.activeCodexModelID else { return nil }
        return account.models.first { $0.id == id }
    }

    private var remoteProfile: RemoteModelProfile? {
        guard appState.isRemoteActive, let endpoint = appState.engine.activeRemoteEndpoint else { return nil }
        let base = AppPreferencesStore.shared.remoteModelProfile(endpoint: endpoint)
            ?? RemoteModelProfile(provider: endpoint.provider, model: endpoint.model,
                                  providerKey: endpoint.providerID,
                                  providerDisplayName: endpoint.effectiveDisplayName)
        return base.applying(AppPreferencesStore.shared.remoteModelOverride(endpoint: endpoint))
    }

    private var options: [String] {
        if let model = accountModel { return model.supportedReasoningEfforts }
        return remoteProfile?.effectiveReasoningEfforts.map(\.rawValue) ?? []
    }

    private var selected: String? {
        if let model = accountModel {
            return AppPreferencesStore.shared.codexReasoningEffort(modelID: model.id)
        }
        if let endpoint = appState.engine.activeRemoteEndpoint, appState.isRemoteActive {
            return AppPreferencesStore.shared.remoteModelOverride(endpoint: endpoint)?.reasoningEffort
        }
        return nil
    }

    var body: some View {
        let _ = revision
        Group {
            if options.isEmpty {
                LabeledContent("Reasoning") {
                    Text("Not adjustable")
                        .foregroundStyle(.secondary)
                }
                .help("This model does not advertise adjustable reasoning levels.")
            } else {
                Picker("Reasoning", selection: Binding(
                    get: { selected },
                    set: { select($0) })) {
                    Text("Automatic").tag(String?.none)
                    ForEach(options, id: \.self) { effort in
                        Text(effort.capitalized).tag(String?.some(effort))
                    }
                }
                .help("Reasoning effort for the selected model")
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("VampModelPreferencesChanged"))) { _ in revision &+= 1 }
    }

    private func select(_ effort: String?) {
        guard effort == nil || options.contains(effort!) else { return }
        if let model = accountModel {
            AppPreferencesStore.shared.saveCodexReasoningEffort(effort, modelID: model.id)
        } else if appState.isRemoteActive, let endpoint = appState.engine.activeRemoteEndpoint {
            var override = AppPreferencesStore.shared.remoteModelOverride(endpoint: endpoint) ?? RemoteModelOverride()
            override.reasoningEffort = effort
            AppPreferencesStore.shared.saveRemoteModelOverride(override, endpoint: endpoint)
        }
        revision &+= 1
    }
}
