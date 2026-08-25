import SwiftUI

@main
struct BeetCodeRemoteApp: App {
    @State private var store = RemoteStore()
    @AppStorage("remoteAppearance") private var appearance = RemoteAppearance.dark

    var body: some Scene {
        WindowGroup {
            RemoteRootView(store: store)
                .tint(BeetTheme.control(appearance))
                .environment(\.remoteAppearance, appearance)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    if UserDefaults.standard.string(forKey: "remoteAppearance") == "beet" {
                        appearance = .dark
                    }
                    await store.restore()
                }
        }
    }
}

enum RemoteAppearance: String, CaseIterable, Identifiable {
    case light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

private struct RemoteAppearanceKey: EnvironmentKey {
    static let defaultValue = RemoteAppearance.dark
}

extension EnvironmentValues {
    var remoteAppearance: RemoteAppearance {
        get { self[RemoteAppearanceKey.self] }
        set { self[RemoteAppearanceKey.self] = newValue }
    }
}

enum BeetTheme {
    // The legacy type name remains internal for source compatibility. Every
    // visible value is strictly monochrome.
    static let accent = Color(white: 0.22)
    // Adaptive foreground accent. Status dots, tool labels and section accents
    // all use it, so anything below ~0.9 reads as washed out over the artwork.
    static let accentBright = Color.primary.opacity(0.94)
    static let wash = Color.white.opacity(0.08)

    static func background(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(white: 0.975)
        case .dark: Color(white: 0.065)
        }
    }

    // Surfaces sit on top of the engraving backdrop. At the previous opacities
    // the texture came through every card, which is what made the whole app
    // look faded; these are opaque enough to give content a real ground.
    static func surface(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color.white.opacity(0.88)
        case .dark: Color(white: 0.13).opacity(0.88)
        }
    }

    static func surfaceStrong(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(white: 0.94).opacity(0.95)
        case .dark: Color(white: 0.20).opacity(0.94)
        }
    }

    /// App-wide tint for plain and bordered controls (nav-bar "Cancel", "Save",
    /// menu rows). The dark `accent` used to be the global tint, which left
    /// those labels nearly invisible against a dark background — filled
    /// `borderedProminent` buttons opt back into `accent` explicitly.
    static func control(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(white: 0.20)
        case .dark: Color(white: 0.93)
        }
    }

    static func line(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(white: 0.58).opacity(0.52)
        case .dark: Color(white: 0.66).opacity(0.46)
        }
    }

    static func secondaryText(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(white: 0.22)
        case .dark: Color(white: 0.82)
        }
    }
}
