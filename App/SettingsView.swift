import AppKit
import SwiftUI

// MARK: - In-app settings workspace

/// Full-height settings destination embedded in the main app.
///
/// Navigation is a permanent 64pt icon-only rail (including its trailing
/// divider) that begins below the native top band and runs to the bottom of
/// the usable content area. Tab names appear as an overlay tooltip on hover
/// or keyboard focus — the rail never widens and the page never shifts.
///
/// The content column is centered against the FULL window width, not the
/// area beside the rail: the content region reserves an invisible 64pt
/// trailing inset matching the rail, so centering inside the remainder lands
/// the column on the window's true center.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared
    private let onClose: () -> Void

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case general = "General"
        case models = "Models & Providers"
        case agent = "Agent"
        case bots = "Bots"
        case network = "Network"
        case plugins = "Plugins"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .models: "square.stack.3d.up"
            case .agent: "cpu"
            case .bots: "person.3"
            case .network: "network"
            case .plugins: "puzzlepiece"
            }
        }
    }

    @State private var tab: Tab
    /// Which half of the merged Models & Providers tab to show. Held here so
    /// a `.openProviderSettings` posted while another tab is on screen still
    /// lands on Providers once the tab switches.
    @State private var modelsSection: ModelsAndProvidersTab.Section = .library

    init(
        initialTab: Tab = .general,
        initialModelsSection: ModelsAndProvidersTab.Section = .library,
        onClose: @escaping () -> Void = {
            NotificationCenter.default.post(name: .openAssistantHome, object: nil)
        }
    ) {
        self.onClose = onClose
        _tab = State(initialValue: initialTab)
        _modelsSection = State(initialValue: initialModelsSection)
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                // A named native sidebar, not a column of unlabelled glyphs:
                // Settings is a place you read, so its sections say what they
                // are. "Back to Assistant" leads it, where a Mac app puts a
                // return action.
                List(selection: $tab) {
                    Section {
                        ForEach(Tab.allCases) { item in
                            Label(item.rawValue, systemImage: item.icon)
                                .tag(item)
                        }
                    } header: {
                        Button(action: onClose) {
                            Label("Back to Assistant", systemImage: "chevron.left")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.sidebar)
                // Narrow windows give the sections less room rather than
                // pushing the page's own controls off the right edge.
                .frame(width: min(208, max(148, proxy.size.width * 0.32)))
                .accessibilityLabel("Settings sections")

                Divider()

                ScrollView {
                    SettingsColumn(
                        windowWidth: proxy.size.width,
                        maxWidth: tab == .models ? SettingsColumnMetrics.modelsMaxWidth
                                                 : SettingsColumnMetrics.maxWidth
                    ) {
                        pageHeader
                        Group {
                            switch tab {
                            case .general: GeneralTab()
                            case .models:
                                ModelsAndProvidersTab(section: $modelsSection)
                                    .environmentObject(appState)
                            case .agent: AgentTab()
                            case .bots: BotsTab()
                            case .network: NetworkTab()
                            case .plugins: PluginsTab()
                            }
                        }
                    }
                }
                .defaultScrollAnchor(.top, for: .sizeChanges)
                .transaction { $0.animation = nil }
                .background(Color.clear)
            }
        }
        .frame(minWidth: 520, minHeight: 620)
        // The window root owns the single continuous atmosphere. Restarting
        // it here would stack a second wallpaper layer with its own crop.
        .tint(Theme.accent)
        .onExitCommand(perform: onClose)
        // Both destinations live on one tab now; ModelsAndProvidersTab reads
        // the same notifications to decide which half of it to show.
        .onReceive(NotificationCenter.default.publisher(for: .openProviderSettings)) { _ in
            tab = .models
            modelsSection = .providers
        }
        .onReceive(NotificationCenter.default.publisher(for: .openModelManager)) { _ in
            tab = .models
            modelsSection = .library
        }
    }

    /// Page title + subtitle, aligned to the same centered column as every
    /// card and control below it. The rail owns "Back to Assistant", so no
    /// duplicate return action lives here.
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tab.rawValue)
                .font(.app(size: 17, weight: .semibold ))
                .foregroundStyle(Theme.textPrimary)
            Text(detailSubtitle)
                .font(.app(size: 13 ))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    private var detailSubtitle: String {
        switch tab {
        case .general: "Theme, composer, keyboard, and launch behaviour"
        case .models: "Everything that answers what runs your next message"
        case .agent: "Autonomy, generation, safety, memory, and Mac control"
        case .bots: "Specialist computers, browser profiles, and orchestration"
        case .network: "The local API server and remote iPhone sessions"
        case .plugins: "Tools, integrations, and capability extensions"
        }
    }
}

// MARK: - Centered settings column

/// One alignment container for the whole page. C = min(800, W − 2·(64 + 24));
/// centered inside the rail-compensated region, so the column's outer edges
/// are equidistant from the window edges while always clearing the rail.
/// Shared metrics for the centered settings column.
enum SettingsColumnMetrics {
    /// Shared maximum settings column width for this revision.
    static let maxWidth: CGFloat = Chrome.pageMaxWidth
    /// The model rack gets one extra equipment bay for aligned metadata and
    /// a stable trailing action column.
    static let modelsMaxWidth: CGFloat = 880
    /// Minimum clearance between the column and the window/rail edges.
    static let clearance: CGFloat = 24
}

private struct SettingsColumn<Content: View>: View {
    let windowWidth: CGFloat
    let maxWidth: CGFloat
    @ViewBuilder var content: Content

    private var columnWidth: CGFloat {
        min(maxWidth,
            max(280, windowWidth - 2 * SettingsColumnMetrics.clearance))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionGap) {
            content
        }
        .frame(width: columnWidth, alignment: .leading)
        // The centering region is the rail-compensated window width, pinned
        // to the viewport's leading edge. A legacy always-visible scrollbar
        // narrows the viewport on the trailing side only; pinning (instead of
        // centering the region) keeps the column on the window's true center
        // and lets the spare trailing margin sit under the scrollbar.
        .frame(width: regionWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Chrome.pageTopPadding)
        .padding(.bottom, Chrome.pageBottomPadding)
    }

    private var regionWidth: CGFloat {
        max(columnWidth, windowWidth)
    }
}

// MARK: - Icon rail
