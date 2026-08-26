import SwiftUI
import UIKit

@main
struct BeetCodeRemoteApp: App {
    @State private var store = RemoteStore()
    @AppStorage("remoteAppearance") private var appearance = RemoteAppearance.dark

    var body: some Scene {
        WindowGroup {
            RemoteRootView(store: store)
                // accent is a button *fill*; as a tint it left spinners and
                // controls dim. accentBright tracks the foreground instead.
                .tint(BeetTheme.accentBright)
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

    // ponytail: dynamic UIColor instead of an `accent(_ appearance:)` function
    // so the ~20 call sites stay untouched. It always sits behind white glyphs,
    // so dark mode needs a *lighter* gray — at white 0.22 the filled buttons
    // scored 1.6:1 against the 0.075 background and vanished.
    static let accent = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.40, alpha: 1)   // 5.7:1 vs white glyph, 3.2:1 vs bg
            : UIColor(white: 0.20, alpha: 1)
    })
    static let accentBright = Color.primary.opacity(0.82)
    static let wash = Color.white.opacity(0.08)

    static func background(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(white: 0.97)
        case .dark: Color(white: 0.075)
        }
    }

    // Cards stay translucent: they are a tint over `remoteGlass`'s material,
    // never a substitute for it. Legibility over the engraving comes from the
    // blur behind them — pushing alpha up instead just flattens the glass.
    static func surface(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color.white.opacity(0.72)
        case .dark: Color(white: 0.12).opacity(0.72)
        }
    }

    static func surfaceStrong(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(white: 0.93).opacity(0.82)
        case .dark: Color(white: 0.19).opacity(0.80)
        }
    }

    static func line(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(white: 0.55).opacity(0.55)
        case .dark: Color(white: 0.70).opacity(0.42)
        }
    }

    // Was 0.22 / 0.82 — near-identical to primary, so captions carried no
    // hierarchy. These still clear 5:1 on their own surfaces.
    static func secondaryText(_ appearance: RemoteAppearance) -> Color {
        switch appearance {
        case .light: Color(white: 0.38)
        case .dark: Color(white: 0.68)
        }
    }
}
