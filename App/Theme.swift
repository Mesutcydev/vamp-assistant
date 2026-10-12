import AppKit
import SwiftUI

@Observable
private final class ThemeAppearanceState: @unchecked Sendable {
    var appearance: AppAppearance = .system
}

/// Vamp Assistant's single source of truth for color. Every surface, text tier and
/// status color resolves through here so light and dark stay coherent by
/// construction instead of per-view `colorScheme ? … : …` guesses.
///
/// Aesthetic: pearl light surfaces or graphite dark surfaces carrying one
/// user-chosen accent.
enum Theme {
    // Read at DRAW time (colors) or body-evaluation time (fonts), so a change
    // takes effect live without recreating the type. All four are mirrored
    // from SettingsStore by `ThemeSync` in BeetCodeApp, on the main actor,
    // before any view below it resolves a color or a font.
    nonisolated(unsafe) static var currentPalette: AccentPalette = .beetRed
    private static let appearanceState = ThemeAppearanceState()
    static var currentAppearance: AppAppearance {
        get { appearanceState.appearance }
        set { appearanceState.appearance = newValue }
    }
    nonisolated(unsafe) static var currentTextSize: AppTextSize = .comfortable
    nonisolated(unsafe) static var currentTypeface: AppTypeface = .sans

    /// Palette-driven dynamic color: resolves the CURRENT palette's hex
    // pair for the active appearance on every draw.
    private static func paletteColor(
        light: KeyPath<AccentPalette.Hexes, UInt32>,
        dark: KeyPath<AccentPalette.Hexes, UInt32>
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hexes = currentPalette == .beetRed
                ? AccentPalette.Hexes(accentLight: 0x7A1F3D, accentDark: 0x9D4E66, brightLight: 0x7A1F3D, brightDark: 0xD6A2B3)
                : currentPalette.hexes
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? hexes[keyPath: dark] : hexes[keyPath: light]
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green:   CGFloat((hex >> 8) & 0xFF) / 255,
                           blue:    CGFloat(hex & 0xFF) / 255,
                           alpha:   1)
        })
    }

    // Flat, coordinated content surfaces. Native materials belong to navigation.
    static var workspaceCanvas: Color { Color.dynamic(light: 0xF6F7F9, dark: 0x191919, oled: 0x000000) }
    static var navigationSurface: Color { Color.dynamic(light: 0xEEF0F4, dark: 0x151515, oled: 0x000000) }
    static var headerSurface: Color { workspaceCanvas }
    static var readingSurface: Color { Color.dynamic(light: 0xFFFFFF, dark: 0x242424, oled: 0x000000) }
    static var navigationTop: Color { navigationSurface }
    static var navigationBottom: Color { navigationSurface }
    static var navigationRowHover: Color { textPrimary.opacity(0.05) }
    static let textOnSilver = Color.dynamic(light: 0x1B1D24, dark: 0xEFEDEB, oled: 0xECEFF4)
    static let secondaryOnSilver = Color.dynamic(light: 0x5C6470, dark: 0xAAA7A4, oled: 0xAAB3C1)
    static let placeholderOnSilver = secondaryOnSilver
    static var controlInsert: Color { accent }
    static let textOnControlInsert = Color.white
    static let structuralDivider = Color.dynamic(light: 0xD9DDE5, dark: 0x383838, oled: 0x363C47)
    static var bg: Color { workspaceCanvas }
    static var surface: Color { Color.dynamic(light: 0xFFFFFF, dark: 0x242424, oled: 0x14171C) }
    static var surfaceInset: Color { Color.dynamic(light: 0xEEF0F4, dark: 0x202020, oled: 0x0B0D11) }
    static let hairline = structuralDivider
    static let composerStroke = structuralDivider
    static let sidebarWash = Color.clear
    static var librarySurface: Color { navigationSurface }
    static let libraryTextPrimary = textOnSilver
    static let libraryTextSecondary = secondaryOnSilver
    static let libraryRowHover = textOnSilver.opacity(0.05)
    static var libraryRowSelected: Color { accent.opacity(0.12) }
    static let chromeWash = Color.clear
    static let textPrimary = textOnSilver
    static let textSecondary = secondaryOnSilver
    static let textTertiary = secondaryOnSilver
    static var sectionSurfaceTop: Color { surface }
    static var sectionSurface: Color { surface }
    static var sectionSurfaceBottom: Color { surface }
    static var wellSurface: Color { surfaceInset }
    static let sectionStroke = structuralDivider
    static let sectionStrokeStrong = structuralDivider
    static let inkPrimary = textOnSilver
    static let inkSecondary = secondaryOnSilver
    static let inkTertiary = secondaryOnSilver
    static let tintChat = Color.dynamic(light: 0x2F6FB0, dark: 0x6FB2E8, oled: 0x7CBCEF)
    static let tintCoding = Color.dynamic(light: 0x6A4BB5, dark: 0xB194F0, oled: 0xB99FF4)
    static let tintVision = Color.dynamic(light: 0x0F7A6B, dark: 0x54C9B4, oled: 0x64D3BE)
    static let rose = Color.dynamic(light: 0x7A1F3D, dark: 0xD6A2B3)
    static let positive = Color.dynamic(light: 0x255B34, dark: 0x7FCA92)
    static let negative = Color.dynamic(light: 0x8E352F, dark: 0xED958B)
    static let controlStrong = Color.dynamic(light: 0x1B1D24, dark: 0xEFEDEB)
    static let statusNeutral = secondaryOnSilver
    static let cardShadow = Color.black.opacity(0.06)

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
        case .dark, .oled: NSAppearance(named: .darkAqua)
        }
        // The window keeps AppKit's own background. Forcing a custom
        // `backgroundColor` here opted the window out of the standard titlebar
        // material, so the transcript stayed legible straight through the
        // toolbar (and over the traffic lights) as it scrolled under it.
        for window in NSApplication.shared.windows {
            configureTitlebar(of: window)
        }
    }

    /// NavigationSplitView already accounts for the unified toolbar. Removing
    /// the full-size content style mask adds a second top inset over the detail
    /// column, hiding the Bots and Devices headers behind a blank grey strip.
    @MainActor static func configureTitlebar(of window: NSWindow) {
        guard window.styleMask.contains(.titled) else { return }
        window.titlebarAppearsTransparent = false
        // macOS 26 insets the sidebar column a few points below the toolbar and
        // rounds its top-left corner. Whatever that inset leaves uncovered is
        // the WINDOW's background, and the default one is pure black in OLED —
        // which reads as a black notch beside the first sidebar row and a black
        // line running down the leading edge. Making the window's own
        // background the navigation plane means the inset can only ever show
        // navigation surface; the transcript canvas covers its own area opaque,
        // so nothing else changes. Re-applied with the appearance, so OLED,
        // dark and light each keep their own surface colour.
        window.backgroundColor = NSColor(Theme.navigationTop)
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
    static let card: CGFloat = 10
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
    static let buttonHeight: CGFloat = 32
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
    static let searchHeight: CGFloat = 32
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
    static let maxWidth: CGFloat = 760
}

/// One mathematical control scale shared by every surface. Everything steps
/// on the same 4pt grid: the frame bars are 46, keybed controls are 34,
/// frameless marks are 28 (control minus one step and a half), and glyphs
/// step 12 / 14 / 16. A control is always `mark + 6`; a bar is always
/// `control + 12`.
enum InstrumentScale {
    static let grid: CGFloat = 4
    /// Frame bar thickness (rail, tab strip, control column, bottom bar).
    static let bar: CGFloat = 46
    /// Keybed control height — moulded keys and the send cap.
    static let control: CGFloat = 34
    /// Frameless mark: the hit target for a printed icon on any surface.
    static let mark: CGFloat = 28
    /// Glyphs: dense rows, marks, and the toolbar bar.
    static let microGlyph: CGFloat = 12
    static let markGlyph: CGFloat = 14
    static let barGlyph: CGFloat = 16
    /// One corner step for marks.
    static let markRadius: CGFloat = 5
}

/// App typography. The instrument system uses clean engineered sans for all
/// controls and prose. Code, diffs, and technical values stay monospaced at
/// the call site.
enum AppFont {
    /// Prose: the user's chosen reading family at answer body size.
    static var chatBody: Font { .appProse(size: 15) }
    /// User prose: 14pt, one step quieter than answers.
    static var chatUserBody: Font { .appProse(size: 14.5) }
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
    static func dynamic(light: UInt32, dark: UInt32, oled: UInt32? = nil) -> Color {
        let resolvedDark = Theme.currentAppearance == .oled ? (oled ?? dark) : dark
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? resolvedDark : light
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

/// Instrument button: a moulded key in the deck's one material, primary in the
/// dark tone. 28pt high, 6pt radius, and a real 1pt travel on press.
struct LFCapsuleButtonStyle: ButtonStyle {
    var tone: LFButtonTone = .secondary
    var height: CGFloat = Chrome.buttonHeight
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Chrome.buttonRadius, style: .continuous)
    }

    /// The app's button face, in system parts: a prominent accent fill for the
    /// primary action, the standard control face otherwise, with destructive
    /// intent carried by the label's colour the way AppKit does it.
    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        let primary = tone == .primary
        return configuration.label
            .font(.system(size: 13, weight: primary ? .semibold : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, Chrome.buttonHPadding)
            .frame(minHeight: height)
            .background(shape.fill(primary
                                   ? Theme.accent
                                   : Theme.surfaceInset))
            .overlay(shape.strokeBorder(primary ? .clear : Theme.hairline,
                                        lineWidth: 1))
            .contentShape(shape)
            .brightness(down ? -0.06 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: down)
    }

    private var foreground: Color {
        switch tone {
        case .primary: Color.white
        case .destructive: Theme.negative
        default: Theme.textPrimary
        }
    }
}

/// Circular moulded cap. Same construction as the rectangular key; only the
/// silhouette differs.
struct LFIconButtonStyle: ButtonStyle {
    var tone: LFButtonTone = .secondary
    var size: CGFloat = 28
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        return configuration.label
            .foregroundStyle(isEnabled
                             ? (tone == .primary ? Color.white : Instrument.ink)
                             : Instrument.inkSecondary)
            .frame(width: size, height: size)
            .environment(\.instrumentPressed, down)
            .instrumentKey(Circle(), tone: tone == .primary ? .dark : .silver)
            .contentShape(Circle())
            .animation(reduceMotion ? nil
                       : (down ? .easeOut(duration: 0.045) : .easeOut(duration: 0.16)),
                       value: down)
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
