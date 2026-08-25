import AppKit
import SwiftUI

// MARK: - In-app settings workspace

/// Full-height settings destination embedded in the main app.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case agent = "Agent"
        case bots = "Bots"
        case providers = "Providers"
        case plugins = "Plugins"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .agent: "cpu"
            case .bots: "square.stack.3d.up"
            case .providers: "key"
            case .plugins: "puzzlepiece"
            }
        }
    }

    @State private var tab: Tab = .general

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { option in
                Label(option.rawValue, systemImage: option.icon)
                    .font(.body.weight(.medium))
                    .padding(.vertical, 7)
                    .tag(option)
            }
            .navigationTitle("Settings")
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tab.rawValue).font(.title2.weight(.semibold))
                        Text(detailSubtitle).font(.callout).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button {
                        NotificationCenter.default.post(name: .openAssistantHome, object: nil)
                    } label: { Label("Done", systemImage: "xmark") }
                    .buttonStyle(LFCapsuleButtonStyle())
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .background(Theme.surface)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

                Group {
                    switch tab {
                    case .general: GeneralTab()
                    case .agent: AgentTab()
                    case .bots: BotsTab()
                    case .providers: ProvidersTab()
                    case .plugins: PluginsTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .background(Theme.bg)
        .tint(Theme.accent)
        .onReceive(NotificationCenter.default.publisher(for: .openProviderSettings)) { _ in
            tab = .providers
        }
    }

    private var detailSubtitle: String {
        switch tab {
        case .general: "Appearance, composer, shortcuts, downloads, and remote access"
        case .agent: "Autonomy, generation, safety, memory, and Mac control"
        case .bots: "Specialist computers, browser profiles, and orchestration"
        case .providers: "Local, account, and API model connections"
        case .plugins: "Tools, integrations, and capability extensions"
        }
    }
}
