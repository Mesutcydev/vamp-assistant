import AppKit
import SwiftUI

/// Vamp Assistant's single source of truth for color. Every surface, text tier and
/// status color resolves through here so light and dark stay coherent by
/// construction instead of per-view `colorScheme ? … : …` guesses.
///
/// Aesthetic: neutral gray surfaces carrying one user-chosen accent.
enum Theme {
    // Read at DRAW time (colors) or body-evaluation time (fonts), so a change
    // takes effect live without recreating the type. All four are mirrored
    // from SettingsStore by `ThemeSync` in BeetCodeApp, on the main actor,
    // before any view below it resolves a color or a font.
    nonisolated(unsafe) static var currentPalette: AccentPalette = .graphite
    nonisolated(unsafe) static var currentAppearance: AppAppearance = .system
    nonisolated(unsafe) static var currentTextSize: AppTextSize = .comfortable
    nonisolated(unsafe) static var currentTypeface: AppTypeface = .sans

    /// Palette-driven dynamic color: resolves the CURRENT palette's hex
    // pair for the active appearance on every draw.
    private static func paletteColor(
        light: KeyPath<AccentPalette.Hexes, UInt32>,
        dark: KeyPath<AccentPalette.Hexes, UInt32>
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hexes = currentPalette.hexes
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? hexes[keyPath: dark] : hexes[keyPath: light]
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green:   CGFloat((hex >> 8) & 0xFF) / 255,
                           blue:    CGFloat(hex & 0xFF) / 255,
                           alpha:   1)
        })
    }

    // MARK: Instrument shell — silver by day, graphite by night.
    // Paired surfaces and inks preserve the same construction in both modes.
    static let workspaceCanvas = Color.dynamic(light: 0xECECE9, dark: 0x222222)
    static let navigationSurface = Color.dynamic(light: 0xDEDEDA, dark: 0x2C2C2C)
    static let headerSurface = Color.dynamic(light: 0xE3E3DF, dark: 0x2F2F2F)
    static let readingSurface = Color.dynamic(light: 0xF1F1EE, dark: 0x262626)
    static let textOnSilver = Color.dynamic(light: 0x242625, dark: 0xECECEB)
    static let secondaryOnSilver = Color.dynamic(light: 0x50534E, dark: 0xBCBCB8)
    static let placeholderOnSilver = Color.dynamic(light: 0x575A55, dark: 0xAEAEAA)
    /// Dark inserted controls stay dark in BOTH appearances — that is the
    /// instrument language, not a dark-mode adaptation.
    static let controlInsert = Color.fixed(0x222423)
    static let textOnControlInsert = Color.fixed(0xF7F7F3)
    static let structuralDivider = Color.dynamic(light: 0xB8BAB4, dark: 0x505050)

    // Shared neutral aliases used by reading, settings, and transient surfaces.
    static let bg           = workspaceCanvas
    static let surface      = Color.dynamic(light: 0xF4F4F2, dark: 0x333333)
    static let surfaceInset = Color.dynamic(light: 0xE2E2E0, dark: 0x282828)
    // Structural seams: engraved dark line on silver. 0.75pt, never thick.
    static let hairline = Color.dynamic(light: 0x000000, dark: 0xFFFFFF).opacity(0.14)
    /// Composer outline — slightly stronger than structural hairlines.
    static let composerStroke = Color.dynamic(light: 0xC9C9C9, dark: 0x595959).opacity(0.85)
    /// Sidebar wash over the instrument canvas.
    static let sidebarWash = Color.dynamic(light: 0xFFFFFF, dark: 0x333333).opacity(0.72)
    /// Conversation-library surface: a near-opaque quiet panel in the same
    /// silver family as the drawer body.
    static let librarySurface = Color.dynamic(light: 0xF5F5F6, dark: 0x2D2D2D)
    static let libraryTextPrimary = textOnSilver
    static let libraryTextSecondary = secondaryOnSilver
    static let libraryRowHover = Color.dynamic(light: 0xEBEBEE, dark: 0x393939)
    static let libraryRowSelected = Color.dynamic(light: 0xE1E1E6, dark: 0x454545)
    /// Header / composer translucent fill.
    static let chromeWash = Color.dynamic(light: 0xFFFFFF, dark: 0x333333).opacity(0.78)

    // Text tiers resolve alongside their surface, including native controls.
    static let textPrimary   = Color.dynamic(light: 0x1C1C1E, dark: 0xECECEB)
    static let textSecondary = Color.dynamic(light: 0x4B4E4A, dark: 0xBFBFBB)
    static let textTertiary  = Color.dynamic(light: 0x51534F, dark: 0xACACA8)
    static let rose          = Color.dynamic(light: 0x913E58, dark: 0xD68CA4)

    // Semantic ink, not decorative fills. Signal LEDs use Instrument tokens.
    static let positive      = Color.dynamic(light: 0x255B34, dark: 0x7FCA92)
    static let negative      = Color.dynamic(light: 0x8E352F, dark: 0xED958B)
    static let controlStrong = Color.fixed(0x686868)
    static let statusNeutral = Color.fixed(0x8E8E93)

    /// Elevation shadow: a whisper on the silver shell, always.
    static let cardShadow = Color(nsColor: NSColor(name: nil) { _ in
        NSColor.black.withAlphaComponent(0.12)
    })

    // Accent — resolved live from the user's palette choice.
    static var accent: Color { paletteColor(light: \.accentLight, dark: \.accentDark) }
    static var accentBright: Color { paletteColor(light: \.brightLight, dark: \.brightDark) }
    /// Accent for FOREGROUND use — text, glyphs, chips. `accent` is a fill
    /// (white text sits on it), which pins its dark value low enough to fail
    /// AA when it is used the other way round. This keeps the light value and
    /// lifts the dark one to the bright step: 5.2–5.9:1 instead of 3.3–3.8:1.
    static var accentText: Color { paletteColor(light: \.accentLight, dark: \.brightDark) }
    static var accentSoft: Color { accent.opacity(0.14) }

    static let success = positive
    static let warning = Color.dynamic(light: 0x72490F, dark: 0xDEB570)
    static let danger  = negative
    static let info    = Color.dynamic(light: 0x2A5578, dark: 0x8AB8DA)

    // Tint washes — the ONLY opacities views may use for tinted fills and
    // borders, so "washed" surfaces read identically everywhere in the app.
    // (0.07/0.10/0.12/0.14/0.16/0.18/0.30/0.35/0.38 all used to appear.)
    static func wash(_ tint: Color) -> Color { tint.opacity(0.10) }
    static func washStrong(_ tint: Color) -> Color { tint.opacity(0.16) }
    static func washBorder(_ tint: Color) -> Color { tint.opacity(0.35) }

    /// Palette wash for the primary (user) surface and glows — accent to
    // bright variant, resolved live from the current palette.
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentBright],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Keep AppKit's app-wide appearance in lockstep with the user's setting so
    /// the dynamic `NSColor` providers above resolve to the *forced* scheme —
    /// not merely the OS one — matching SwiftUI's `preferredColorScheme`.
    @MainActor static func applyAppearance(_ appearance: AppAppearance) {
        currentAppearance = appearance
        NSApplication.shared.appearance = switch appearance {
        case .system: nil
        case .light:  NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        // NavigationSplitView's unused trailing gutter is the window
        // background — leave it themed, never default black.
        let fill = NSColor(Theme.bg)
        for window in NSApplication.shared.windows {
            window.backgroundColor = fill
        }
    }
}

/// Corner radii — one scale, used everywhere for a consistent silhouette.
enum Radius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 10
    static let xl: CGFloat = 12
    // Reference-export cards and controls keep their own steps so the
    // transcript surfaces stay distinct from general window chrome.
    static let card: CGFloat = 8
    static let bubble: CGFloat = 12
    static let control: CGFloat = 6
}

/// Window chrome + control geometry exported by the reference artboard.
/// One place so the toolbar, status strip, composer, and every settings
/// control repeat the same heights, insets, and gaps instead of drifting
/// per screen.
enum Chrome {
    /// Combined top chrome band (titlebar + toolbar) at reference size.
    static let topBandHeight: CGFloat = 52
    /// Trailing toolbar buttons: 28 high, 8 radius, solid control fill.
    static let toolbarButtonHeight: CGFloat = 28
    static let toolbarButtonRadius: CGFloat = Radius.control
    static let toolbarIcon: CGFloat = 16
    /// Composer chips and quiet pills: 26 high, 13 radius, 10 side padding.
    static let chipHeight: CGFloat = 26
    static let chipRadius: CGFloat = 13
    static let chipHPadding: CGFloat = 10
    /// Action buttons (approval, settings, cards): 28 high, 8 radius.
    static let buttonHeight: CGFloat = 28
    static let buttonRadius: CGFloat = Radius.control
    static let buttonHPadding: CGFloat = 14
    /// Status strip above the composer.
    static let statusHeight: CGFloat = 30
    static let statusHPadding: CGFloat = 22
    static let statusItemGap: CGFloat = 18
    /// Composer outer / inner padding and circular send control.
    static let composerOuterTop: CGFloat = 12
    static let composerOuterHPadding: CGFloat = 22
    static let composerOuterBottom: CGFloat = 16
    static let composerInnerTop: CGFloat = 12
    static let composerInnerHPadding: CGFloat = 14
    static let composerInnerBottom: CGFloat = 10
    static let sendSize: CGFloat = 28
    /// Search fields (sidebar, model filter): 32 high, 8 radius.
    static let searchHeight: CGFloat = 34
    static let searchRadius: CGFloat = Radius.control
    /// Settings / dashboard content column and page padding.
    static let pageMaxWidth: CGFloat = 800
    static let pageHPadding: CGFloat = 24
    static let pageTopPadding: CGFloat = 24
    static let pageBottomPadding: CGFloat = 28
    static let sectionGap: CGFloat = 16
    /// Outline card padding (settings groups, bot cards).
    static let cardVPadding: CGFloat = 12
    static let cardHPadding: CGFloat = 14
    /// Bottom-dock composer: maximum width, workspace gutter, bottom inset,
    /// and the gap between suggestions/status and the chassis.
    static let composerMaxWidth: CGFloat = 960
    static let composerGutter: CGFloat = 24
    // The chassis is the bottom edge of the product, like the approved
    // hardware reference. Extra safe-area space belongs inside the chassis,
    // never as a floating gap beneath it.
    static let composerBottomGap: CGFloat = 0
    static let dockGap: CGFloat = 12
}

/// The centered reading column shared by the transcript and the composer.
/// The reference artboard runs the conversation in a 700pt column centered
/// in the main pane; the composer deliberately spans wider (22pt side
/// insets) and does not use this cap.
enum ContentColumn {
    static let maxWidth: CGFloat = 700
}

/// App typography. The instrument system uses clean engineered sans for all
/// controls and prose. Code, diffs, and technical values stay monospaced at
/// the call site.
enum AppFont {
    /// Prose: the user's chosen reading family at answer body size.
    static var chatBody: Font { .appProse(size: 14.5) }
    /// User prose: 14pt, one step quieter than answers.
    static var chatUserBody: Font { .appProse(size: 14) }
    static var chatHeading: Font { .appProse(size: 18, weight: .semibold) }
    /// Folder / project group in the sidebar — parent of chat rows.
    static var navigationGroup: Font { .appUI(size: 13.5, weight: .semibold) }
    /// Chat title inside a group — child of `navigationGroup`.
    static var navigationTitle: Font { .appUI(size: 13, weight: .medium) }
    static var navigationMeta: Font { .appUI(size: 11) }
    static var editor: Font { .appUI(size: 14) }
    /// Compact engineered brand lockup used on the welcome screen.
    static var homeWordmark: Font { .appUI(size: 25, weight: .semibold) }
    static var homeInvitation: Font { .appUI(size: 13.5) }
}

/// Spacing — 4pt grid. Use these instead of ad-hoc padding literals.
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
}

extension Color {
    /// An appearance-independent color for invariant inserts and signal marks.
    static func fixed(_ hex: UInt32) -> Color {
        Color(hex: hex)
    }

    /// A color that resolves light/dark from a hex pair with no intermediate
    /// `Color`→`NSColor` round-trip (keeps the sRGB values exact).
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green:   CGFloat((hex >> 8) & 0xFF) / 255,
                           blue:    CGFloat(hex & 0xFF) / 255,
                           alpha:   1)
        })
    }

    /// Convenience for one-off literals (e.g. gradients).
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension Font {
    /// Product identity is independent of the user-selected prose typeface.
    static func brandWordmark(compact: Bool) -> Font {
        .system(size: compact ? 25 : 30, weight: .semibold, design: .default)
    }

    static func brandMicroLabel(compact: Bool) -> Font {
        .system(size: compact ? 8.5 : 9.5, weight: .medium, design: .monospaced)
    }

    /// App text that honours the user's Text Size setting.
    ///
    /// `.system(size:)` is a fixed point size, so every literal call site
    /// silently opted out of the preference — it reached only the handful of
    /// `AppFont` tokens, leaving the setting a no-op across most of the UI.
    /// `design` defaults to `.default` so swapping a call site never changes
    /// the typeface, only whether it scales.
    static func app(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: size * CGFloat(Theme.currentTextSize.scale),
                weight: weight,
                design: resolvedDesign(design))
    }

    /// Engineered UI text: clean system sans at every call site — controls,
    /// labels, chrome, settings rows. NEVER follows the Typeface preference;
    /// controls stay identical no matter what family the user reads prose in.
    static func appUI(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * CGFloat(Theme.currentTextSize.scale),
                weight: weight,
                design: .default)
    }

    /// Reading prose (transcript answers, long-form copy): resolves through
    /// the user's Typeface preference — Serif / Sans / Rounded / Mono.
    static func appProse(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * CGFloat(Theme.currentTextSize.scale),
                weight: weight,
                design: resolvedDesign(.serif))
    }

    /// Technical text: monospaced, still honoring Text Size.
    static func appMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * CGFloat(Theme.currentTextSize.scale),
                weight: weight,
                design: .monospaced)
    }

    /// Maps a requested design onto the user's Typeface setting. `.serif` is
    /// the app's "this is prose" request, so it becomes whatever the user
    /// picked; anything else (explicit `.default`, monospaced code) is a
    /// deliberate non-prose choice and is passed through untouched.
    static func resolvedDesign(_ requested: Font.Design) -> Font.Design {
        guard requested == .serif else { return requested }
        return switch Theme.currentTypeface {
        case .serif: .serif
        case .sans: .default
        case .rounded: .rounded
        case .mono: .monospaced
        }
    }
}

extension View {
    /// Standard elevated card: silver faceplate with engraved seam.
    func lfCard(radius: CGFloat = Radius.lg) -> some View {
        instrumentFaceplate(radius: radius, shadow: false)
    }

    /// Cursor/ChatGPT-style hover affordance for small chips and accessory
    /// buttons: a +0.03 brightness lift, a pointing cursor, and a hairline
    /// tint so interactive controls are never mistaken for static text.
    /// Reduce Motion is respected automatically (no animation, just a
    /// pointer + brightness change — both non-animated).
    func lfHoverLift() -> some View {
        modifier(HoverLiftModifier())
    }

    /// Press confirmation for plain buttons (Run, chips, footer tools).
    func lfPressScale() -> some View {
        buttonStyle(LFPlainPressButtonStyle())
    }

    /// Semantic accent-washed card (approval / question / plan / error).
    func lfWashCard(_ tint: Color, radius: CGFloat = Radius.lg) -> some View {
        background(Theme.wash(tint), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.washBorder(tint), lineWidth: 1))
    }

    /// Compatibility entry point for older panels; renders the shared opaque
    /// silver surface while preserving callers and native interaction.
    func lfGlass(
        radius: CGFloat = Radius.lg,
        contentLegibility: Bool = true,
        hovering: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .modifier(LFGlassModifier(shape: shape))
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5)
                .allowsHitTesting(false))
            .shadow(color: Theme.cardShadow, radius: 4, y: 1)
            .brightness(hovering ? 0.025 : 0)
    }
}

/// Opaque silver replacement for the legacy glass presentation.
private struct LFGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    func body(content: Content) -> some View {
        content
            .background(LinearGradient(
                colors: [Instrument.silverTop, Instrument.silverLow],
                startPoint: .top, endPoint: .bottom), in: shape)
            .overlay(shape.strokeBorder(Instrument.seam, lineWidth: 0.75))
    }
}

/// Hover affordance (U5): pointer cursor + a small brightness lift so chips
/// and accessory buttons read as interactive. pointerStyle is macOS 15+,
/// which is our deployment target — no availability gate needed.
private struct HoverLiftModifier: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .pointerStyle(hovering ? .link : .default)
            .brightness(hovering ? 0.03 : 0)
    }
}

/// Plain chrome with instant press confirmation. Small actions that draw
/// their own chrome use this style so feedback stays consistent.
struct LFPlainPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12),
                       value: configuration.isPressed)
    }
}

/// A small semantic vocabulary for actions. Text actions use a capsule and
/// icon-only actions use a circle; neither falls back to generic rectangular
/// AppKit buttons, so hierarchy remains clear without adding visual weight.
enum LFButtonTone {
    case secondary
    case primary
    case destructive

    var foreground: Color {
        switch self {
        case .secondary: Instrument.ink
        case .primary: .white
        case .destructive: Theme.negative
        }
    }

    var fill: Color {
        switch self {
        case .secondary: Instrument.silverMid
        case .primary: Instrument.darkInsert
        case .destructive: Instrument.silverMid
        }
    }

    var border: Color {
        switch self {
        case .secondary: Instrument.seam
        case .primary: Color.clear
        case .destructive: Theme.negative.opacity(0.5)
        }
    }
}

/// Instrument button: silver key with engraved seam; primary is a dark
/// inserted control. 28pt high, 8pt radius, tactile press.
struct LFCapsuleButtonStyle: ButtonStyle {
    var tone: LFButtonTone = .secondary
    var height: CGFloat = Chrome.buttonHeight
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Chrome.buttonRadius, style: .continuous)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(size: 12.5, weight: tone == .primary ? .semibold : .medium))
            .foregroundStyle(isEnabled ? tone.foreground : Instrument.inkSecondary)
            .padding(.horizontal, Chrome.buttonHPadding)
            .frame(minHeight: height)
            .background(
                isEnabled
                    ? LinearGradient(colors: tone == .primary
                                     ? [Instrument.darkInsert, Instrument.darkInsert]
                                     : [Instrument.silverTop, Instrument.silverLow],
                                     startPoint: .top, endPoint: .bottom)
                    : LinearGradient(colors: [Instrument.silverMid, Instrument.silverLow],
                                     startPoint: .top, endPoint: .bottom),
                in: shape)
            .overlay(shape.strokeBorder(
                isEnabled ? tone.border : Instrument.seam.opacity(0.6),
                lineWidth: 0.75))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .opacity(isEnabled ? 1 : 0.85)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10),
                       value: configuration.isPressed)
    }
}

/// Circular silver control with machined edge.
struct LFIconButtonStyle: ButtonStyle {
    var tone: LFButtonTone = .secondary
    var size: CGFloat = 28
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled
                             ? (tone == .primary ? Color.white : Instrument.ink)
                             : Instrument.inkSecondary)
            .frame(width: size, height: size)
            .background(
                Circle().fill(
                    LinearGradient(colors: tone == .primary && isEnabled
                                     ? [Instrument.darkInsert, Instrument.darkInsert]
                                     : [Instrument.silverTop, Instrument.silverLow],
                                   startPoint: .top, endPoint: .bottom)))
            .overlay(Circle().strokeBorder(
                tone == .primary && isEnabled ? Color.white.opacity(0.12) : Instrument.seam,
                lineWidth: 0.75))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10),
                       value: configuration.isPressed)
    }
}

/// Shared panel dismiss control — one glyph, one help string.
struct PanelCloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.app(size: 11, weight: .semibold ))
        }
        .buttonStyle(LFIconButtonStyle(size: 26))
        .lfHoverLift()
        .help("Close panel")
        .accessibilityLabel("Close panel")
    }
}
