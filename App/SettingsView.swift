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
                SettingsRail(selected: $tab, onBack: onClose)

                // Invisible trailing reservation equal to the rail width:
                // centering inside the remainder puts the column on the
                // window's true center (see SettingsColumn below).
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
                .background(Color.clear)
                .padding(.trailing, SettingsRail.width)
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
            max(280, windowWidth - 2 * (SettingsRail.width + SettingsColumnMetrics.clearance)))
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
        max(columnWidth, windowWidth - 2 * SettingsRail.width)
    }
}

// MARK: - Icon rail

/// Permanent 64pt icon-only navigation rail. Hover/focus reveals the tab
/// name in an overlay tooltip anchored to the icon — never a layout child,
/// so the rail width and page position are immutable.
struct SettingsRail: View {
    @Binding var selected: SettingsView.Tab
    let onBack: () -> Void

    /// Rail width including its trailing divider.
    static let width: CGFloat = SidebarMetrics.collapsedWidth
    private static let buttonSize: CGFloat = SidebarMetrics.railTarget
    private static let iconSize: CGFloat = SidebarMetrics.railIcon
    private static let gap: CGFloat = 6
    private static let selectionRadius: CGFloat = SidebarMetrics.railRadius

    @State private var hovered: SettingsView.Tab?
    @State private var tooltipTab: SettingsView.Tab?
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var focused: SettingsView.Tab?

    /// Dev-only visual-verification hooks (`--design-preview settings-hover`
    /// / `settings-focus`): deterministic hover/focus states for capture.
    /// Never set in production launches.
    @MainActor static var previewHover: SettingsView.Tab?
    @MainActor static var previewFocus: SettingsView.Tab?

    /// Anchor centers of each tab button, for exact tooltip placement.
    private struct TabAnchors: PreferenceKey {
        static let defaultValue: [SettingsView.Tab: Anchor<CGPoint>] = [:]
        static func reduce(value: inout [SettingsView.Tab: Anchor<CGPoint>],
                           nextValue: () -> [SettingsView.Tab: Anchor<CGPoint>]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            railButton(icon: "chevron.left",
                       label: "Back to Assistant",
                       selected: false,
                       action: onBack)
                .accessibilityLabel("Back to Assistant")

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.75)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)

            VStack(spacing: Self.gap) {
                ForEach(SettingsView.Tab.allCases) { option in
                    railButton(icon: option.icon,
                               label: option.rawValue,
                               selected: option == selected,
                               isFocused: focused == option,
                               action: { selected = option })
                        .anchorPreference(key: TabAnchors.self, value: .center) {
                            [option: $0]
                        }
                        .focused($focused, equals: option)
                        .onChange(of: focused) { _, newValue in
                            tooltipTab = newValue
                        }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .frame(width: Self.width - 0.75)
        .frame(maxHeight: .infinity)
        .background {
            LinearGradient(colors: [Instrument.silverTop, Instrument.silverMid, Instrument.silverLow],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(.container, edges: [.bottom])
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Instrument.seam).frame(width: 0.75)
        }
        .overlayPreferenceValue(TabAnchors.self) { anchors in
            tooltipOverlay(anchors: anchors)
        }
        .onHover { inside in
            if !inside { clearHover() }
        }
        .onAppear {
            if let preview = Self.previewHover {
                hovered = preview
                tooltipTab = preview
            }
            if let preview = Self.previewFocus {
                focused = preview
                tooltipTab = preview
            }
        }
    }

    private func railButton(icon: String, label: String, selected: Bool,
                            isFocused: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: Self.iconSize, weight: .medium))
                .foregroundStyle(selected ? Color.white : hoveredLabel(label) ? Instrument.ink : Instrument.inkSecondary)
                .frame(width: SidebarMetrics.railFace, height: SidebarMetrics.railFace)
                .background(
                    selected ? AnyShapeStyle(Instrument.darkInsert)
                        : AnyShapeStyle(LinearGradient(
                            colors: [Instrument.silverTop, Instrument.silverLow],
                            startPoint: .top, endPoint: .bottom)),
                    in: RoundedRectangle(cornerRadius: Self.selectionRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Self.selectionRadius, style: .continuous)
                        .strokeBorder(Instrument.ink.opacity(isFocused ? 0.6 : 0),
                                      lineWidth: 1.5)
                        .padding(2)
                )
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .overlay(alignment: .leading) {
                    if selected {
                        Capsule()
                            .fill(Instrument.accentOrange)
                            .frame(width: SidebarMetrics.railMarkerWidth,
                                   height: SidebarMetrics.railMarkerHeight)
                            .padding(.leading, SidebarMetrics.railMarkerInset)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Self.selectionRadius,
                                               style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if let option = SettingsView.Tab.allCases.first(where: { $0.rawValue == label }) {
                setHover(option, inside: inside)
            }
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func hoveredLabel(_ label: String) -> Bool {
        hovered?.rawValue == label
    }

    private func setHover(_ option: SettingsView.Tab, inside: Bool) {
        if inside {
            hovered = option
            hoverTask?.cancel()
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, hovered == option else { return }
                tooltipTab = option
            }
        } else if hovered == option {
            clearHover()
        }
    }

    private func clearHover() {
        hovered = nil
        hoverTask?.cancel()
        hoverTask = nil
        if focused == nil { tooltipTab = nil }
    }

    /// Overlay tooltip: leading edge 8pt clear of the rail, vertically
    /// centered on the hovered icon, opaque dark surface, hairline border.
    /// It takes no layout width and never intercepts clicks. Placement uses
    /// a fixed offset from the rail edge, so nothing depends on measured
    /// label geometry and the first frame is already correct.
    private static let tooltipHeight: CGFloat = 26

    @ViewBuilder
    private func tooltipOverlay(anchors: [SettingsView.Tab: Anchor<CGPoint>]) -> some View {
        GeometryReader { proxy in
            if let tooltipTab, let anchor = anchors[tooltipTab] {
                let center = proxy[anchor]
                tooltipLabel(tooltipTab)
                    .offset(x: Self.width + 8,
                            y: center.y - Self.tooltipHeight / 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }

    private func tooltipLabel(_ option: SettingsView.Tab) -> some View {
        Text(option.rawValue)
            .font(.app(size: 12.5, weight: .medium ))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.surface,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.75))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .fixedSize()
    }
}
