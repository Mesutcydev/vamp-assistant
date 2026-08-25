import Foundation

/// Configurable composer interaction-motion presets. Raw values remain
/// stable so existing preferences migrate without a reset.
/// Lives in Core (not App) because SettingsStore persists the selection and
/// the CLI target must compile without the UI layer; each preset's SwiftUI
/// motion rendering lives in the App-layer ComposerStyle.swift file.
enum ComposerFlow: String, CaseIterable, Identifiable, Codable, Sendable {
    case aurora
    case ember
    case ocean
    case graphite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aurora: "Full perimeter flow"
        case .ember: "Traveling highlight"
        case .ocean: "Interaction pulse"
        case .graphite: "Static hairline"
        }
    }

    var help: String {
        switch self {
        case .aurora: "A soft highlight continuously traces the entire composer."
        case .ember: "A short light segment travels around the edge."
        case .ocean: "The border breathes when focused, working, or awaiting approval."
        case .graphite: "No continuous motion; state changes use a quiet monochrome line."
        }
    }

    /// Seconds per full motion cycle; slower = calmer.
    var cycleSeconds: Double {
        switch self {
        case .aurora: 6
        case .ember: 4
        case .ocean: 7
        case .graphite: 9
        }
    }
}
