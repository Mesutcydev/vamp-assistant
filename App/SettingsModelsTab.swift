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

    var body: some View {
        VStack(spacing: 0) {
            sectionBar

            switch section {
            case .library:
                ModelManagerView(embedded: true)
                    .environmentObject(appState)
            case .providers:
                ProvidersTab()
                    .environmentObject(appState)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sectionBar: some View {
        HStack(spacing: Spacing.md) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { option in
                    Label(option.rawValue, systemImage: option.icon).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Text(section.summary)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Theme.surface.opacity(0.62))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline.opacity(0.72)).frame(height: 0.75)
        }
    }
}
