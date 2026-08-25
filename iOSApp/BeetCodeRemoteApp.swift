import SwiftUI

@main
struct BeetCodeRemoteApp: App {
    @State private var store = RemoteStore()
    @AppStorage("remoteAppearance") private var appearance = RemoteAppearance.dark

    var body: some Scene {
        WindowGroup {
            RemoteRootView(store: store)
                .tint(BeetTheme.accent)
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
    // Adaptive foreground accent: the previous fixed light gray was readable
    // on OLED black but nearly disappeared over the light engraving artwork.
    static let accentBright = Color.primary.opacity(0.78)
    static let wash = Color.white.opacity(0.08)

    static func background(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(white: 0.965)
        case .dark: Color(white: 0.045)
        }
    }

    static func surface(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color.white.opacity(0.78)
        case .dark: Color(white: 0.07).opacity(0.68)
        }
    }

    static func surfaceStrong(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(white: 0.93).opacity(0.90)
        case .dark: Color(white: 0.13).opacity(0.76)
        }
    }

    static func line(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(white: 0.62).opacity(0.42)
        case .dark: Color(white: 0.62).opacity(0.34)
        }
    }

    static func secondaryText(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(white: 0.26)
        case .dark: Color(white: 0.76)
        }
    }
}
