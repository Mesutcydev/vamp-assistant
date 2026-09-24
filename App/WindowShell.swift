import AppKit
import SwiftUI

// MARK: - Native window shell
//
// The window is a standard macOS three-column app: sidebar (destinations +
// conversations), detail (transcript + composer), inspector (status and the
// per-model controls). Everything here is a system control — the frame rails,
// the painted status lamps, and the vertical FIXED fader they replaced were
// custom drawings of things AppKit already provides.

/// The sidebar's fixed destinations, above the conversation list.
enum ShellDestination: String, Hashable, CaseIterable, Identifiable {
    case conversations, bots, devices

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversations: "Conversations"
        case .bots: "Bots"
        case .devices: "Devices"
        }
    }

    var symbol: String {
        switch self {
        case .conversations: "bubble.left.and.bubble.right"
        case .bots: "person.2"
        case .devices: "iphone"
        }
    }
}

/// The window's leading column: the fixed destinations, then the existing
/// conversation library. The library view already owns session loading,
/// selection-to-restore, rename/delete, import, and pinning — it is mounted
/// here rather than reimplemented.
struct ShellSidebar: View {
    @Binding var destination: ShellDestination
    @Binding var historySearch: String
    @Binding var showRemoteAccess: Bool
    var onSettings: () -> Void
    var onOpenInNewWindow: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            destinations
            SidebarDivider(inset: SidebarMetrics.inset)
            if destination == .conversations {
                SidebarView(showRemoteAccess: $showRemoteAccess,
                            onClose: {},
                            historySearch: $historySearch,
                            onOpenInNewWindow: onOpenInNewWindow)
            } else {
                Spacer(minLength: 0)
            }
        }
        // One plane for the whole column, flush with the window's leading,
        // top and bottom edges — the library below is a region of it, not a
        // panel of its own.
        .sidebarSurface()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarNavRow(title: "Settings", systemImage: "gearshape", action: onSettings)
                .padding(.bottom, SidebarMetrics.navRowsBottomInset)
        }
    }

    /// The fixed destinations. Rows are drawn on the column's own surface
    /// instead of by a nested sidebar `List`: the system's selection slab put a
    /// second grey panel inside the column, and its rows did not share the
    /// workspace row's text axis.
    private var destinations: some View {
        VStack(spacing: SidebarMetrics.navRowSpacing) {
            ForEach(ShellDestination.allCases) { item in
                SidebarNavRow(title: item.title,
                              systemImage: item.symbol,
                              isSelected: destination == item,
                              isTopRow: item == .conversations) {
                    destination = item
                }
            }
        }
        .padding(.top, SidebarMetrics.navRowsTopInset)
        .padding(.bottom, SidebarMetrics.navRowsBottomInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Destinations")
    }
}

// MARK: - Toolbar search

/// A real `NSSearchField` in the toolbar's centre. SwiftUI's `.searchable`
/// puts its field wherever the platform chooses; this app needs it centred and
/// sized like Safari's, so the native control is hosted directly — still the
/// one toolbar owner, still AppKit's rendering, focus ring, and cancel button.
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Return in the field. Never submits a prompt — this field only navigates.
    var onCommit: () -> Void = {}

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.focusRingType = .default
        // Low hugging is deliberate: the field shares its toolbar item with a
        // transparent centring spacer, and the field must not stretch into it.
        // A width constraint here loses to the toolbar's own required sizing
        // (measured), so the width is held by the item instead — see
        // `pinSearchFieldWidth()`.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField

        init(_ parent: ToolbarSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func commit(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            parent.onCommit()
        }
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
