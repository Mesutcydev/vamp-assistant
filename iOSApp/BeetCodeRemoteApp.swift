import SwiftUI
import UIKit

@main
struct BeetCodeRemoteApp: App {
    @State private var store = RemoteStore()

    var body: some Scene {
        WindowGroup {
            RemoteRootShell(store: store)
        }
    }
}

/// Resolves the user's theme choice, then hands the resolved light/dark value
/// down as `\.remoteAppearance`. It has to be a child of the scene rather than
/// the scene itself: `System` means "whatever `\.colorScheme` says", and that
/// can only be read from a view whose own environment is still the system's.
private struct RemoteRootShell: View {
    let store: RemoteStore
    @AppStorage("remoteAppearanceSetting") private var setting = RemoteAppearanceSetting.dark
    @AppStorage("remoteAccent") private var accent = AccentPalette.graphite
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase

    private var appearance: RemoteAppearance { setting.resolved(systemScheme) }

    var body: some View {
        RemoteRootView(store: store)
            // accent is a button *fill*; as a tint it left spinners and
            // controls dim. accentBright tracks the foreground instead.
            .tint(BeetTheme.accentBright)
            .environment(\.remoteAppearance, appearance)
            .preferredColorScheme(setting.colorScheme)
            .onChange(of: accent, initial: true) { _, palette in
                BeetTheme.currentPalette = palette
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { Task { await store.drafts.flush() } }
            }
            .task {
                RemoteAppearanceSetting.migrateLegacyDefault()
                await store.restore()
            }
    }
}

/// What the user picked. Distinct from `RemoteAppearance`, which is the
/// *resolved* light-or-dark value every surface draws against — keeping them
/// separate is what let System be added without touching ~100 call sites.
enum RemoteAppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    /// nil lets iOS decide, which is what makes `\.colorScheme` readable as
    /// the system value one level up.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func resolved(_ systemScheme: ColorScheme) -> RemoteAppearance {
        switch self {
        case .system: systemScheme == .light ? .light : .dark
        case .light: .light
        case .dark: .dark
        }
    }

    /// Older builds stored the resolved value under `remoteAppearance`, and
    /// one build wrote the retired `beet` case. Carry both forward once.
    static func migrateLegacyDefault() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "remoteAppearanceSetting") == nil else { return }
        let legacy = defaults.string(forKey: "remoteAppearance")
        defaults.set(legacy == "light" ? light.rawValue : dark.rawValue,
                     forKey: "remoteAppearanceSetting")
    }
}

/// The resolved appearance every surface draws against.
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

extension EnvironmentValues {
    @Entry var remoteAppearance: RemoteAppearance = .dark
}

@MainActor
@Observable
private final class RemotePaletteState {
    var palette = UserDefaults.standard.string(forKey: "remoteAccent")
        .flatMap(AccentPalette.init(rawValue:)) ?? .graphite
}

enum BeetTheme {
    @MainActor private static let paletteState = RemotePaletteState()
    @MainActor static var currentPalette: AccentPalette {
        get { paletteState.palette }
        set { paletteState.palette = newValue }
    }

    /// Dynamic UIColor rather than an `accent(_ appearance:)` function so the
    /// ~20 call sites stay untouched. `accent` always sits behind white glyphs;
    /// every palette's pair is contrast-checked for exactly that (see
    /// `AccentPalette`), which is why dark mode uses the lighter of the two.
    @MainActor static var accent: Color {
        let hexes = currentPalette.hexes
        return Color(uiColor: UIColor { trait in
            uiColor(trait.userInterfaceStyle == .dark ? hexes.accentDark : hexes.accentLight)
        })
    }

    /// Foreground step — text, glyphs, and status dots. `accent` is a fill, so
    /// using it the other way round fails contrast on the app's surfaces.
    @MainActor static var accentBright: Color {
        let hexes = currentPalette.hexes
        return Color(uiColor: UIColor { trait in
            uiColor(trait.userInterfaceStyle == .dark ? hexes.brightDark : hexes.accentLight)
        })
    }

    static let wash = Color.white.opacity(0.08)

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

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
