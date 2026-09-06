import Foundation

// Shared theme vocabulary. Foundation-only and deliberately free of any
// other Core type so the iOS client can compile the same palette the Mac
// app uses instead of keeping a second copy of the hexes in sync by hand.

/// Accent color palettes. Every entry ships a light+dark hex pair for both
/// the accent and its brighter variant; `Theme` resolves them at draw time.
/// Every pair is checked against the neutrals it lands on: `accentLight` and
/// `accentDark` are fills that carry white glyphs (>= 4.5:1 vs white), and
/// `brightDark` is the dark-mode FOREGROUND step (>= 4.5:1 on `surfaceInset`).
/// Foundation-only (no SwiftUI) so the CLI target can compile this file;
/// the SwiftUI swatch extension lives in App/Theme.swift.
enum AccentPalette: String, CaseIterable, Codable, Identifiable, Sendable {
    case clay
    case sage
    case ink
    case graphite
    case beetRed
    case rose
    case amber
    case forest
    case ocean
    case indigo
    case violet

    /// Explicit order — this is the swatch order in Settings, not source order.
    static let allCases: [AccentPalette] = [
        .graphite, .ink, .clay, .sage, .beetRed, .rose, .amber, .forest, .ocean, .indigo, .violet,
    ]

    var id: String { rawValue }

    struct Hexes: Sendable, Equatable {
        var accentLight: UInt32
        var accentDark: UInt32
        var brightLight: UInt32
        var brightDark: UInt32
    }

    var label: String {
        switch self {
        case .clay: "Clay"
        case .sage: "Sage"
        case .ink: "Ink"
        case .graphite: "Graphite"
        case .beetRed: "Beet"
        case .rose: "Rose"
        case .amber: "Amber"
        case .forest: "Forest"
        case .ocean: "Ocean"
        case .indigo: "Indigo"
        case .violet: "Violet"
        }
    }

    var hexes: Hexes {
        switch self {
        // Natural, low-chroma pairs — the register the chat assistants settled
        // on, and the one that suits a tool you keep open for hours. Every
        // value here is contrast-checked the same way as the rest: the accents
        // carry white glyphs, brightDark sits on the dark grouped cell.
        case .clay:
            Hexes(accentLight: 0x9A4B2E, accentDark: 0xB05E3C,
                  brightLight: 0xA65033, brightDark: 0xE0906E)
        case .sage:
            Hexes(accentLight: 0x3D6B52, accentDark: 0x487A5C,
                  brightLight: 0x456F57, brightDark: 0x7FC49D)
        case .ink:
            Hexes(accentLight: 0x33415C, accentDark: 0x445677,
                  brightLight: 0x3B4A69, brightDark: 0x9DAECF)
        case .graphite:
            Hexes(accentLight: 0x303030, accentDark: 0x686868,
                  brightLight: 0x505050, brightDark: 0x888888)
        case .beetRed:
            Hexes(accentLight: 0x9B1B42, accentDark: 0xB03055,
                  brightLight: 0xB33357, brightDark: 0xE87A9C)
        case .rose:
            Hexes(accentLight: 0xA81F5D, accentDark: 0xC13570,
                  brightLight: 0xBE2E6C, brightDark: 0xF287B6)
        case .amber:
            Hexes(accentLight: 0x8A5200, accentDark: 0xA36200,
                  brightLight: 0xA36200, brightDark: 0xE0A44A)
        case .forest:
            Hexes(accentLight: 0x1F6B3B, accentDark: 0x2C7D4A,
                  brightLight: 0x27804A, brightDark: 0x6FC98C)
        case .ocean:
            Hexes(accentLight: 0x0E6E86, accentDark: 0x1A7E96,
                  brightLight: 0x14829C, brightDark: 0x5FC5DE)
        case .indigo:
            Hexes(accentLight: 0x4338CA, accentDark: 0x5B4FD6,
                  brightLight: 0x5B50E0, brightDark: 0xA5A0F5)
        case .violet:
            Hexes(accentLight: 0x6D28D9, accentDark: 0x7C3AED,
                  brightLight: 0x7C3AED, brightDark: 0xC0A6FA)
        }
    }
}

/// Typeface for the app's proportional reading and navigation text. Code,
/// diffs, and diagnostics keep their monospaced faces at the call site — this
/// only swaps the family used for prose and chrome.
enum AppTypeface: String, CaseIterable, Codable, Identifiable, Sendable {
    case serif
    case sans
    case rounded
    case mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .serif: "Serif"
        case .sans: "Sans"
        case .rounded: "Rounded"
        case .mono: "Mono"
        }
    }

    var help: String {
        switch self {
        case .serif: "New York — an editorial serif."
        case .sans: "San Francisco — the system face, and the default."
        case .rounded: "SF Rounded — softer, friendlier chrome."
        case .mono: "SF Mono — everything in a fixed pitch."
        }
    }
}
