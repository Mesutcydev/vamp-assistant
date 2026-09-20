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

    /// DEBUG-only QA knob: `VAMP_TEST_APPEARANCE=light|dark` forces the whole
    /// shell so fixture captures are deterministic even when the persisted
    /// setting is pinned dark. Ignored in release builds.
    private var testAppearance: RemoteAppearanceSetting? {
#if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["VAMP_TEST_APPEARANCE"] else { return nil }
        return RemoteAppearanceSetting(rawValue: raw)
#else
        return nil
#endif
    }

    private var effectiveSetting: RemoteAppearanceSetting { testAppearance ?? setting }
    private var appearance: RemoteAppearance { effectiveSetting.resolved(systemScheme) }

    var body: some View {
        RemoteRootView(store: store)
            // accent is a button *fill*; as a tint it left spinners and
            // controls dim. accentBright tracks the foreground instead.
            .foregroundStyle(RemoteInstrument.ink)
            .tint(BeetTheme.accentBright)
            .environment(\.remoteAppearance, appearance)
            .preferredColorScheme(effectiveSetting.colorScheme)
            .onChange(of: accent, initial: true) { _, palette in
                BeetTheme.currentPalette = palette
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { Task { await store.drafts.flush() } }
            }
            .task {
#if DEBUG
                // Native design fixtures never restore a real Mac connection.
                if ProcessInfo.processInfo.environment["VAMP_REMOTE_TEST_SCREEN"] != nil { return }
#endif
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

    /// Fill and foreground accents remain distinct for contrast in both themes.
    @MainActor static var accent: Color {
        RemoteInstrument.adaptive(currentPalette.hexes.accentLight, 0x777777)
    }

    @MainActor static var accentBright: Color {
        RemoteInstrument.adaptive(currentPalette.hexes.accentLight,
            0xD0D0D0)
    }

    static let wash = Color.white.opacity(0.08)

    // Compatibility aliases keep every existing screen on one material system.
    static func background(_ appearance: RemoteAppearance) -> Color { RemoteInstrument.canvas }
    static func surface(_ appearance: RemoteAppearance) -> Color { RemoteInstrument.panel }
    static func surfaceStrong(_ appearance: RemoteAppearance) -> Color { RemoteInstrument.recess }
    static func line(_ appearance: RemoteAppearance) -> Color { RemoteInstrument.seam }
    static func readingSurface(_ appearance: RemoteAppearance) -> Color { RemoteInstrument.reading }
    static func tertiaryText(_ appearance: RemoteAppearance) -> Color { RemoteInstrument.secondaryInk }
    static func secondaryText(_ appearance: RemoteAppearance) -> Color { RemoteInstrument.secondaryInk }
}
