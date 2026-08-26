import AppKit
import SwiftUI

// MARK: - In-app settings workspace

/// Full-height settings destination embedded in the main app.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared
    private let onClose: () -> Void

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case general = "General"
        case models = "Models"
        case agent = "Agent"
        case bots = "Bots"
        case providers = "Providers"
        case plugins = "Plugins"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .models: "square.stack.3d.up"
            case .agent: "cpu"
            case .bots: "person.3"
            case .providers: "key"
            case .plugins: "puzzlepiece"
            }
        }
    }

    @State private var tab: Tab

    init(initialTab: Tab = .general, onClose: @escaping () -> Void = {
        NotificationCenter.default.post(name: .openAssistantHome, object: nil)
    }) {
        self.onClose = onClose
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        // Root row, not a NavigationSplitView: on macOS 26 a split view wraps
        // its sidebar in an inset, rounded concentric-glass panel, which is
        // what gave the navigation column its own corners inside the window.
        HStack(spacing: 0) {
            // One container for the back action, the separator, and the
            // destinations: a single horizontal inset they cannot drift apart
            // on, and a separator that ends exactly where the rows end instead
            // of running into the column's vertical divider.
            VStack(spacing: 0) {
                // A navigation row, not a panel — same inset, icon width, and
                // row height as the destinations below it.
                SidebarNavRow(title: "Back to Assistant", icon: "chevron.left", action: onClose)
                    .help("Return to Vamp Assistant")
                    .padding(.top, SidebarMetrics.inset)

                SidebarDivider(inset: 0)
                    .padding(.vertical, 7)

                // No ScrollView: six fixed rows always fit, and a scroll view
                // adds its own horizontal content inset.
                VStack(spacing: 2) {
                    ForEach(Tab.allCases) { option in
                        SidebarNavRow(title: option.rawValue,
                                      icon: option.icon,
                                      selected: option == tab) {
                            tab = option
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, SidebarMetrics.inset)
            .navigationTitle("Settings")
            // Same surface as the History drawer: one material running up
            // under the titlebar and out through the split view's leading and
            // bottom inset. The window mask is the only corner geometry.
            .frame(width: SidebarMetrics.width)
            .sidebarSurface()

            SidebarSplitDivider()

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tab.rawValue).font(.title2.weight(.semibold))
                        Text(detailSubtitle).font(.callout).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Label("Back to Assistant", systemImage: "chevron.backward")
                    }
                    .buttonStyle(LFCapsuleButtonStyle())
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .background(.thinMaterial)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

                Group {
                    switch tab {
                    case .general: GeneralTab()
                    case .models:
                        ModelManagerView(embedded: true)
                            .environmentObject(appState)
                    case .agent: AgentTab()
                    case .bots: BotsTab()
                    case .providers: ProvidersTab()
                    case .plugins: PluginsTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 620)
        .background { AtmosphereBackground(intensity: .conversation) }
        .tint(Theme.accent)
        .onExitCommand(perform: onClose)
        .onReceive(NotificationCenter.default.publisher(for: .openProviderSettings)) { _ in
            tab = .providers
        }
        .onReceive(NotificationCenter.default.publisher(for: .openModelManager)) { _ in
            tab = .models
        }
    }

    private var detailSubtitle: String {
        switch tab {
        case .general: "Appearance, composer, shortcuts, downloads, and remote access"
        case .models: "Local models, memory budget, downloads, and remote providers"
        case .agent: "Autonomy, generation, safety, memory, and Mac control"
        case .bots: "Specialist computers, browser profiles, and orchestration"
        case .providers: "Local, account, and API model connections"
        case .plugins: "Tools, integrations, and capability extensions"
        }
    }
}
