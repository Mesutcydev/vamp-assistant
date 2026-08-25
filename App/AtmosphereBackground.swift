import SwiftUI

/// Window atmosphere — a classical engraving behind the page, the way Hermes
/// sits a figure behind chat: visible on the empty home, quieter under text.
struct AtmosphereBackground: View {
    enum Intensity {
        case conversation
        case home
    }

    var intensity: Intensity = .conversation
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.bg
                if !reduceTransparency {
                    Image("WindowAtmosphere")
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .opacity(artOpacity)
                        .blendMode(blend)
                        .saturation(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    Theme.bg.opacity(washOpacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(Theme.bg)
    }

    private var artOpacity: Double {
        switch (intensity, settings.appearance) {
        case (.home, .light): 0.18
        case (.home, .beet): 0.24
        case (.home, .dark), (.home, .system): 0.22
        case (.conversation, .light): 0.09
        case (.conversation, .beet): 0.15
        case (.conversation, .dark), (.conversation, .system): 0.13
        }
    }

    private var washOpacity: Double {
        switch (intensity, settings.appearance) {
        case (.home, .light): 0.28
        case (.home, .beet): 0.34
        case (.home, .dark), (.home, .system): 0.38
        case (.conversation, .light): 0.48
        case (.conversation, .beet): 0.48
        case (.conversation, .dark), (.conversation, .system): 0.52
        }
    }

    private var blend: BlendMode {
        settings.appearance == .light ? .multiply : .plusLighter
    }
}
