import SwiftUI

@main
struct BeetCodeRemoteApp: App {
    @State private var store = RemoteStore()
    @AppStorage("remoteAppearance") private var appearance = RemoteAppearance.beet

    var body: some Scene {
        WindowGroup {
            RemoteRootView(store: store)
                .tint(BeetTheme.accent)
                .environment(\.remoteAppearance, appearance)
                .preferredColorScheme(appearance.colorScheme)
                .task { await store.restore() }
        }
    }
}

enum RemoteAppearance: String, CaseIterable, Identifiable {
    case light, dark, beet

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        case .beet: "drop.fill"
        }
    }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

private struct RemoteAppearanceKey: EnvironmentKey {
    static let defaultValue = RemoteAppearance.beet
}

extension EnvironmentValues {
    var remoteAppearance: RemoteAppearance {
        get { self[RemoteAppearanceKey.self] }
        set { self[RemoteAppearanceKey.self] = newValue }
    }
}

enum BeetTheme {
    static let accent = Color(red: 0.48, green: 0.12, blue: 0.24)
    static let accentBright = Color(red: 0.82, green: 0.28, blue: 0.46)
    static let wash = Color(red: 0.48, green: 0.12, blue: 0.24).opacity(0.1)

    static func background(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(red: 0.965, green: 0.969, blue: 0.976)
        case .dark: Color(red: 0.047, green: 0.055, blue: 0.078)
        case .beet: Color(red: 0.478, green: 0.122, blue: 0.239)
        }
    }

    static func surface(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: .white
        case .dark: Color(red: 0.094, green: 0.110, blue: 0.149)
        case .beet: Color(red: 0.565, green: 0.188, blue: 0.306)
        }
    }

    static func surfaceStrong(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(red: 0.890, green: 0.902, blue: 0.922)
        case .dark: Color(red: 0.137, green: 0.157, blue: 0.216)
        case .beet: Color(red: 0.369, green: 0.086, blue: 0.188)
        }
    }

    static func line(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(red: 0.882, green: 0.894, blue: 0.918)
        case .dark: Color(red: 0.204, green: 0.231, blue: 0.306)
        case .beet: Color(red: 0.659, green: 0.275, blue: 0.408)
        }
    }

    static func secondaryText(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(red: 0.357, green: 0.380, blue: 0.431)
        case .dark: Color(red: 0.639, green: 0.667, blue: 0.733)
        case .beet: Color(red: 0.906, green: 0.722, blue: 0.784)
        }
    }
}
