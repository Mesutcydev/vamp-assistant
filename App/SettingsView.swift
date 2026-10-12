import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.workspaceWindowID) private var workspaceWindowID
    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case general = "General"
        case models = "Models & Connections"
        case agent = "Agent & Permissions"
        case plugins = "Integrations"
        case advanced = "Advanced"
        // Legacy deep links land in Advanced without restoring separate destinations.
        case bots = "Run environments"
        case network = "Network"
        static let navigationTabs: [Tab] = [.general, .models, .agent, .plugins, .advanced]
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .models: "cpu"
            case .agent: "slider.horizontal.3"
            case .plugins: "puzzlepiece"
            case .advanced, .bots, .network: "wrench.and.screwdriver"
            }
        }
        var subtitle: String {
            switch self {
            case .general: "Appearance, keyboard, and app preferences"
            case .models: "Choose what runs your next conversation"
            case .agent: "How the assistant works and what it can access"
            case .plugins: "Skills, commands, project instructions, and connected tools"
            case .advanced, .bots, .network: "Runtime configuration and run environments"
            }
        }
    }
    @State private var tab: Tab
    @State private var modelsSection: ModelsAndProvidersTab.Section
    let embedded: Bool
    let onSelect: ((Tab) -> Void)?
    let onClose: () -> Void

    init(initialTab: Tab = .general, initialModelsSection: ModelsAndProvidersTab.Section = .library,
         embedded: Bool = false, onSelect: ((Tab) -> Void)? = nil,
         onClose: @escaping () -> Void = { NotificationCenter.default.post(name: .openAssistantHome, object: nil) }) {
        _tab = State(initialValue: initialTab)
        _modelsSection = State(initialValue: initialModelsSection)
        self.embedded = embedded
        self.onSelect = onSelect
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { geometry in
            if embedded {
                page(width: geometry.size.width)
            } else {
                HStack(spacing: 0) {
                    List {
                        Button("Back to Assistant", action: onClose)
                        ForEach(Tab.navigationTabs) { item in
                            Button { select(item) } label: { Label(item.rawValue, systemImage: item.icon) }
                        }
                    }.listStyle(.sidebar).frame(width: 200)
                    page(width: max(0, geometry.size.width - 200))
                }
            }
        }
        .background(Theme.workspaceCanvas)
        .tint(Theme.accent)
        .onReceive(NotificationCenter.default.publisher(for: .openProviderSettings)) { note in
            if let target = note.userInfo?["workspaceWindowID"] as? String, target != workspaceWindowID { return }
            modelsSection = .providers; select(.models)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openModelManager)) { note in
            if let target = note.userInfo?["workspaceWindowID"] as? String, target != workspaceWindowID { return }
            modelsSection = .library; select(.models)
        }
    }

    private func select(_ section: Tab) { tab = section; onSelect?(section) }

    private func page(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tab.rawValue).font(.system(size: 24, weight: .semibold))
                        Text(tab.subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    Menu {
                        ForEach(Tab.navigationTabs) { item in
                            Button(item.rawValue) { select(item) }
                        }
                    } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel("Settings sections")
                }
                settingsContent
            }
            .frame(width: max(0, min(960, width - 2 * SettingsColumnMetrics.gutter(forPaneWidth: width))), alignment: .leading)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top)
        .foregroundStyle(Theme.textPrimary)
        .accessibilityIdentifier("settings-page")
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch tab {
        case .general: GeneralTab()
        case .models: ModelsAndProvidersTab(section: $modelsSection)
        case .agent: AgentTab()
        case .plugins: PluginsTab()
        case .advanced, .bots, .network:
            TabScroll {
                NetworkTab()
                BotsTab()
                ExperimentalInferenceCard()
                TypeSafeSettingsCard()
            }
        }
    }
}

enum SettingsColumnMetrics {
    static let baseWidth: CGFloat = 820
    static let modelsBaseWidth: CGFloat = 960
    static let paneFill: CGFloat = 0.85
    static func gutter(forPaneWidth width: CGFloat) -> CGFloat { width < 700 ? 16 : 32 }
}
