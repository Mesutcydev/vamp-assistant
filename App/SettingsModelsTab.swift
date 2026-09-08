import SwiftUI

// MARK: - Models & Providers

/// One destination for everything that answers "what will run my next
/// message": the local library and the remote connections that feed it.
/// They were two sibling tabs, which meant configuring a provider and then
/// picking its model was a navigation round trip every single time.
struct ModelsAndProvidersTab: View {
    @EnvironmentObject private var appState: AppState

    enum Section: String, CaseIterable, Identifiable {
        case library = "Library"
        case providers = "Providers"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .library: "square.stack.3d.up"
            case .providers: "key"
            }
        }

        var summary: String {
            switch self {
            case .library: "Local models on this Mac, plus every configured remote model"
            case .providers: "Accounts, API keys, and compatible gateways"
            }
        }
    }

    /// Owned by `SettingsView`: `.openProviderSettings` can arrive before this
    /// view exists (Settings opens first, the destination request follows), so
    /// the selection has to live one level up or the notification is lost.
    @Binding var section: Section
    @State private var compactSectionBar = false

    var body: some View {
        VStack(spacing: 12) {
            sectionBar
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            switch section {
            case .library:
                ModelManagerView(embedded: true)
                    .environmentObject(appState)
            case .providers:
                ProvidersTab()
                    .environmentObject(appState)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: Bool.self) { $0.size.width < 600 } action: {
            compactSectionBar = $0
        }
    }

    private var sectionBar: some View {
        let layout = compactSectionBar
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: Spacing.md))
        return layout {
            InstrumentSegmentedControl(
                selection: $section,
                options: Section.allCases.map { ($0.rawValue, $0) })
            .frame(width: 260)
            .accessibilityLabel("Models and providers section")

            Text(section.summary)
                .font(.app(size: 11.5 ))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.75)
        }
    }
}
