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
            case .library: "Download models for this Mac or choose a connected model"
            case .providers: "Choose a provider to connect or manage"
            }
        }
    }

    /// Owned by `SettingsView`: `.openProviderSettings` can arrive before this
    /// view exists (Settings opens first, the destination request follows), so
    /// the selection has to live one level up or the notification is lost.
    @Binding var section: Section

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
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .transaction { $0.animation = nil }

    }

    private var sectionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            InstrumentSegmentedControl(
                selection: $section,
                options: Section.allCases.map { ($0.rawValue, $0) })
            .frame(width: 260)

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
